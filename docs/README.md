# Aria2-in-Browser 模块文档

## 模块全景

```
┌────────────────────────────────────────────────────────────┐
│                      entrypoints/                          │
│  ┌──────────┐  ┌────────────────┐  ┌───────────────────┐  │
│  │  popup/  │  │ background.ts  │  │ main.content.ts   │  │
│  │ (React)  │  │ (ServiceWorker)│  │ (MAIN world)      │  │
│  └──────────┘  └───────┬────────┘  └────────┬──────────┘  │
│                        │                    │              │
│                        │    ┌───────────────┘              │
│                        │    │  CustomEvent                 │
│                        │    ▼                              │
│                        │  ┌───────────────────┐           │
│                        │  │ bridge.content.ts │           │
│                        │  │ (ISOLATED world)  │           │
│                        │  └────────┬──────────┘           │
│                        │           │ runtime.sendMessage  │
│                        ▼           ▼                      │
├────────────────────────────────────────────────────────────┤
│                        core/                               │
│  ┌──────────┐  ┌──────────────────┐  ┌─────────────────┐  │
│  │ types.ts │  │ aria2-handler.ts │  │download-mgr.ts  │  │
│  └──────────┘  └────────┬─────────┘  └────────┬────────┘  │
│                         │                     │            │
│                    ┌────┘                     │            │
│                    ▼                          ▼            │
│              ┌──────────┐          ┌──────────────────┐   │
│              │storage.ts│          │ browser.downloads│   │
│              └──────────┘          │ browser.tabs     │   │
│                                    │ declarativeNetReq│   │
│                                    └──────────────────┘   │
├────────────────────────────────────────────────────────────┤
│                        tests/                              │
│  ┌────────────┐ ┌───────────────┐ ┌────────────────────┐  │
│  │ setup.ts   │ │ aria2-handler │ │ download-manager   │  │
│  │ (browser   │ │   .test.ts    │ │   .test.ts         │  │
│  │  mock)     │ └───────────────┘ └────────────────────┘  │
│  └────────────┘ ┌───────────────┐ ┌────────────────────┐  │
│                 │  storage      │ │ integration        │  │
│                 │   .test.ts    │ │   .test.ts         │  │
│                 └───────────────┘ └────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

## 索引

| 文档 | 内容 |
|------|------|
| [modules/core.md](modules/core.md) | `types.ts` `storage.ts` `download-manager.ts` `aria2-handler.ts` 模块详解 |
| [modules/entrypoints.md](modules/entrypoints.md) | `background.ts` `popup/` `main.content.ts` `bridge.content.ts` 模块详解 |
| [modules/tests.md](modules/tests.md) | `setup.ts` 及各测试文件的架构 |
| [comms.md](comms.md) | 模块间调用关系、数据流、通信协议 |
