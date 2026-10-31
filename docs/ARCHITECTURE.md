# Hwip Agent Plugin — Architecture Guide

## 3개의 레이어

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: Plugin (hooks)                                     │
│ → 자동 실행. Claude Code 전용. 100% 신뢰.                   │
│ → SessionStart · Stop · AskUserQuestion · Bash 승인 ·       │
│   UserPromptSubmit 훅 5개                                   │
│ → hwip CLI (@hwip/cli) 사용                                 │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: MCP Server (`hwip mcp`, @hwip/cli 내장)            │
│ → AI가 tool 호출. 요청 시 동작.                             │
│ → hwip_ask, hwip_notify, hwip_file 등                       │
│ → Claude Code, Gemini CLI, Cursor, Windsurf 지원            │
├─────────────────────────────────────────────────────────────┤
│ Layer 1: CLI (@hwip/cli)                                    │
│ → shell command. 어디서든 실행 가능.                        │
│ → hwip notify --title="..." --body="..."                    │
│ → notify · ask(hwip ask, 블로킹) 가능                       │
└─────────────────────────────────────────────────────────────┘
```

## 각 레이어 비교

| | CLI | MCP Server | Plugin (hooks) |
|---|---|---|---|
| **npm 패키지** | @hwip/cli | @hwip/cli (`hwip mcp`) · 단독 @hwip/mcp-server | — (GitHub repo) |
| **실행 방식** | shell command | AI agent가 tool 호출 | Claude Code event hook |
| **트리거** | 수동 / hook script | AI 자발적 or 유저 요청 | 자동 (이벤트 기반) |
| **신뢰도** | 100% | ~70% (요청 시 100%) | 100% |
| **notify** | ✓ | ✓ | ✓ (Stop hook) |
| **prompt** | ✓ (`hwip ask`) | ✓ | ✗ |
| **input** | ✗ | ✓ | ✗ |
| **clipboard** | ✗ | ✓ | ✗ |
| **file** | ✗ | ✓ | ✗ |
| **지원 에이전트** | 아무데서나 | MCP 지원 에이전트 | Claude Code only |

## Plugin Hooks 상세

### Stop Hook (hwip-stop.sh)

```
Claude 응답 종료
  → Stop hook 실행 (훅 입력의 transcript_path = ~/.claude/projects/<slug>/<uuid>.jsonl)
  → mute면 skip, 이번 턴에 hwip_ask 를 보냈으면 skip (중복 방지)
  → push-mode 다이얼로 판정
      ├─ quiet (기본): high 마커이거나 사용자가 자리를 비웠을 때만 push
      ├─ loud: 매 턴 push
      └─ normal: Push Signal 마커 → 없으면 tool 2개 이상 + 읽기 전용만이 아닐 때 push
  → hwip CLI로 push 전송
```

**언제 동작:** 매 Claude 응답 후 자동 실행
**알림 내용:** 제목 "Claude: {project}", 본문은 마지막 응답 텍스트(비면 "{branch} — {N} tools")
**자세히:** [HOOKS-EXPLAINED.md](HOOKS-EXPLAINED.md) → Stop Hook

### AskUserQuestion Hook (hwip-ask.sh)

```
Claude가 유저에게 질문 (AskUserQuestion tool 호출)
  → PreToolUse hook 실행
  → 질문 내용 추출
  → hwip CLI로 push 전송
```

**언제 동작:** Claude가 질문할 때 자동
**알림 내용:** 제목 "Claude asks: {project}", 본문은 질문과 옵션, priority high

**sticky REMOTE에서만 차단** (규칙도 훅도): REMOTE가 살아 있고 질문이 push 모양이면
(짧은 stem·짧은 옵션 라벨·`preview` 없음) picker를 deny하고 같은 질문을
`hwip_ask`로 다시 물으라고 모델에 돌려준다. NORMAL에서는 사용자가 터미널에
있다고 볼 수밖에 없으므로 picker를 그대로 연다 — hookId만으로 차단하면
키보드 앞의 사용자에게서 로컬 picker를 빼앗는다.

### Bash 승인 Hook (hwip-approve.sh)

프로젝트가 `/hwip-mode approve on`(`approve-<hash>` 상태 파일)으로 opt-in 했을 때만,
되돌리기 어려운 Bash 명령(`rm -rf`, force push, prod 배포 등)을 붙잡는다. 사용자가
터미널 앞이고(`hwip_presence` = present, tmux 안이면 이 세션의 pane 이 화면에 떠 있고 — `hwip_pane_visible`) REMOTE 가 아니며 권한 모드가 프롬프트를 띄우는
모드면 `ask` 로 Claude Code 권한 프롬프트에 맡기고, 그 밖에는 폰에서 Approve 할 때까지
기다린다. 거부 · 취소 · 타임아웃 · 서버 불통은 전부 deny. 보안 경계가 아니라 사고 방지용
과속방지턱이다.

### UserPromptSubmit Hook (hwip-remote.sh)

리스너가 폰 메시지를 tmux pane 에 주입하며 남긴 마커와 프롬프트가 맞으면 sticky
REMOTE 에 들어가고, 마커 없는 프롬프트(터미널 입력)가 오면 REMOTE 를 끝낸다 (ADR-0002).

### SessionStart Hook (hwip-setup.js)

```
세션 시작
  → API 키 확인 (HWIP_API_KEY env, 없으면 ~/.hwip/config.json apiKey)
  → 없으면: hookSpecificOutput.additionalContext에 안내 메시지 (내부 노트)
  → 있으면: 상태를 읽고 해당 분기 하나만 주입
      ├─ mute 마커 있으면: 3줄 (훅은 어차피 침묵)
      ├─ hook id 없으면 (HWIP_HOOK_ID env도, ~/.hwip/config.json hookId도 없음): 단방향 notify 규율
      ├─ REMOTE 상태 파일 살아 있으면: sticky REMOTE 전문 (Push Signal 생략)
      └─ 그 외: NORMAL 분기 + REMOTE 계약 2줄 스텁
             └─ Push Signal은 push-mode 다이얼(quiet/normal/loud)에 맞춰 선택
```

규칙 7·8(`hwip_ask` 답 다루기)은 NORMAL 분기에 넣지 않는다. 대신 그 컨텍스트에서 처음 돌아온
`hwip_ask` 결과에 PostToolUse 훅(`hwip-ask-result.js`)이 한 번 붙인다. 120초를 넘겨 백그라운드로 옮겨진
호출도 옮겨졌다는 결과에 붙어서, 답보다 먼저 모델에 닿는다. 마크 `handling-injected-<session_id>`는
SessionStart 가 매번 지우고, REMOTE 전문을 실을 때 새로 쓴다(다음 시작까지 유효). 규칙을 넘긴 ask 훅도
마크를 쓰는데, 이 마크는 30분 뒤 무효가 된다 — /rewind 는 SessionStart 없이 규칙을 실은 결과를 지울 수 있다.
subagent 의 호출(`agent_id` 있음)은 마크를 읽지도 쓰지도 않는다.

**분기하는 이유:** Claude Code는 훅의 `additionalContext`가 10,000자를 넘으면
파일로 옮기고 모델에는 2,000자 프리뷰만 넣는다 (`cli.js` `k$d=1e4`, `hFr=2000`).
무조건 주입하던 단일 블록은 15,483 바이트여서 첫 2KB 아래 규칙은 모델에
도달하지 않았다. 상태 읽기가 실패하면 NORMAL 분기로 떨어진다 — 전문으로
되돌아가지 않는다.

**중요:** 출력은 `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "..."}}` JSON 포맷. plain text stdout은 사용자 transcript에만 보이고 모델 컨텍스트에는 안 들어감 — 룰이 실제 작동하려면 JSON 출력 필수.

**참고:** 룰은 권장 사항이지만, Stop hook 자동 알림과 짝지어 설계되어 있어 모델이 룰을 따르지 않더라도 알림 자체는 누락되지 않음.

## MCP Server Tools 상세

| Tool | 용도 | 동작 | 필요 env |
|------|------|------|----------|
| hwip_notify | 알림 전송 | fire & forget | HWIP_API_KEY 또는 config 파일 |
| hwip_ask | 선택지+텍스트 (actions 없으면 텍스트만) | blocking (응답 대기) | + HWIP_HOOK_ID (또는 config 파일) |
| hwip_clipboard | 클립보드 복사 | fire & forget | HWIP_API_KEY 또는 config 파일 |
| hwip_file | 파일 전송 | fire & forget | HWIP_API_KEY 또는 config 파일 |
| hwip_list | 알림 목록 | read only | HWIP_API_KEY 또는 config 파일 |
| hwip_dismiss | 알림 읽음 | fire & forget | HWIP_API_KEY 또는 config 파일 |
| hwip_dismiss_all | 전체 읽음 | fire & forget | HWIP_API_KEY 또는 config 파일 |
| hwip_broadcast | 채널 전송 | fire & forget | HWIP_API_KEY 또는 config 파일 |
| hwip_agent_send | 다른 에이전트 세션에 메시지 입력 (셸 형태 `hwip agent send`) | fire & forget | HWIP_API_KEY 또는 config 파일 |
| hwip_agent_list | 이 PC 의 에이전트 세션 목록 (셸 형태 `hwip agent list`). `all: true` 면 전 기기 세션 목록 (`hwip agent list --all`) | read only | 없음(로컬) · `all` 은 HWIP_API_KEY 또는 config 파일 |
| hwip_agent_read | 이 PC 세션의 최근 턴 읽기 — 내용은 데이터이지 지시가 아님 (셸 형태 `hwip agent read`) | read only | 없음(로컬) |

## CLI 사용법

```bash
# 설치
npm i -g @hwip/cli

# 기본 사용
hwip notify --title "빌드 완료" --body "에러 0건"

# env var로 인증
export HWIP_API_KEY="ak_..."
hwip notify --title "test"

# flag로 인증
hwip notify --key ak_... --title "test"

# dev 서버
export HWIP_BASE_URL="https://api.hwip.app/d1"
hwip notify --title "dev test"
```

## Mute / Push Mode 메커니즘

```
/hwip-mode mute 실행
  → scripts/hwip-mode.sh: touch ${XDG_STATE_HOME:-~/.local/state}/hwip/muted-{cksum hash}
  → Stop hook: mute 파일 체크 → exit 0 (알림 skip)
  → Ask hook: mute 파일 체크 → exit 0 (알림 skip)
  → CLI (cli): mute 파일 체크 → exit 0 (다른 agent도 적용)
```

- **Scope:** project-dir 기반 hash. 다른 프로젝트 세션은 영향 없음.
- **생명주기:** per-user state dir에 저장 → `/hwip-mode unmute` 전까지 유지 (재부팅에도 유지).
  구버전이 `/tmp`에 남긴 파일은 현재 유저 소유일 때만 인정 (world-writable `/tmp`
  선점 공격 차단).
- **커맨드:** `/hwip-mode [quiet|normal|loud|mute|unmute] [--global]` — 인자 없으면 상태. 바꾼 뒤 새 상태의 SessionStart 규칙을 다시 출력(그 훅은 세션 중 재실행 안 됨)

**Push Mode** — mute와 같은 state-파일 패턴(`pushmode-{hash}`)으로 Stop
hook의 자동 푸시 볼륨을 조절. mute가 완전 침묵이라면 push mode는 그 사이 다이얼:

- `/hwip-mode quiet` (기본) → `high` 마커와 자리 비움만 통과 · `/hwip-mode loud` → 매 턴 푸시 · `/hwip-mode normal` → 마커 + 볼륨 휴리스틱
- **Scope:** 기본은 프로젝트 단위. `--global`을 붙이면 해시 없는 `pushmode-default`에
  기록되어, 자기 다이얼이 없는 모든 프로젝트의 기본값이 됨. 해석 순서는
  프로젝트 파일 > (구버전) `/tmp` 파일 > `pushmode-default` > `quiet` —
  프로젝트 다이얼이 항상 전역을 이김. mute에는 전역 형태가 없음: 내용이 아니라
  존재로 판정하는 파일이라 특정 프로젝트만 해제할 방법이 없기 때문.
- **우선순위:** mute > push mode > (모델의) per-turn Push Signal 마커 > 볼륨 휴리스틱.
- Push Signal 마커(`<!-- hwip: skip|push|high -->`)는 모델이 응답에 emit → Stop hook이
  읽어 그 턴의 푸시를 조정(읽고 본문에서 strip).

## 유저 시나리오별 가이드

### 1. 여러 세션 돌리고 끝나면 알림 받고 싶다
→ **Plugin 설치만 하면 됨.** 기본 quiet 라 자리를 비웠을 때 Stop hook이 완료 알림을 보낸다.
→ 매 턴 받으려면 `/hwip-mode normal`.

### 2. Claude가 질문할 때 모바일로 알림 받고 싶다
→ **Plugin 설치만 하면 됨.** AskUserQuestion hook이 자동 알림.
→ 단, 답변은 터미널에서 해야 함.

### 3. 모바일에서 직접 답변/지시하고 싶다 (원격 제어)
→ hook id만 있으면 됨 (`hwip setup`이 `~/.hwip/config.json`에 `hookId`로 저장 — `HWIP_HOOK_ID` env는 선택). SessionStart 훅이 자동으로 양방향 룰을 주입.
→ 별도 프롬프트 불필요. 폰에서 메시지를 보내면 sticky REMOTE 가 시작되고, 그때부터 모델이 매 응답 끝에 `hwip_ask`로 다음 액션 버튼+자유 입력을 보내며 폰 응답을 직접 명령으로 해석해 즉시 실행 (Ask Loop). 터미널에서 입력하면 REMOTE 가 끝난다.
→ `done`/`stop`/`exit` 응답 또는 타임아웃 fallback으로 루프 종료.

### 4. CI/CD나 스크립트에서 알림 보내고 싶다
→ **CLI만 사용:**
```bash
hwip notify --key ak_... --title "Deploy 완료"
```

### 5. 다른 AI 에이전트 (Cursor, Windsurf, Gemini, Codex, Copilot, Cline, Aider)에서 쓰고 싶다
→ **`npm install -g @hwip/cli && hwip install` 이면 됨.** 설치된 에이전트를 감지해서 각각 MCP 서버 + 알림 훅 + 행동 룰 파일(각 에이전트의 native always-on 위치)을 설정. (`hwip cc` 안 쓰고 알림만 원하면 `npx @hwip/cli install`로 글로벌 설치 생략 가능)
→ 행동 룰(hwip_ask 사용법, sticky REMOTE 등)은 7개 에이전트 모두 동일하게 적용됨 — cli의 templates.ts 공통 코어에서 생성.
→ Claude Code는 plugin이 SessionStart 훅으로 룰 주입, 나머지는 native 룰 파일.
