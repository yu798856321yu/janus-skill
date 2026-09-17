# 技术栈画像与项目规范 (Profile: Tech Stack)

本文件是项目技术事实、构建入口与隔离红线的填写模板。权限见 `references/control-plane.md`，证据见 `references/verification.md`。

## 使用与修改说明
- 填写位置：复制到项目根下 `docs/tech-stack.md`，由人工填写，或由 Agent 扫描后提议、人工确认；保留既有 `AGENTS.md`。
- 填写规则：保留全部标题与条目，在方括号内填入具体事实；不涉及的项填 NONE，严禁删除条目或自由发挥增删章节。
- 生效时机：项目配置在下次读取时生效，无需重装 skill；当前任务修改后请告知 Agent，重读与复核见 discovery §2。

## 1. 基础环境与工程状态
- 工程状态：[存量改造 | 新建项目]
- 核心语言与版本：[例如：.NET 8 | Node.js 20 | Python 3.11 | Go 1.22]
- 核心框架与技术：[例如：ASP.NET Core | Vue 3 + Vite | FastAPI | Spring Boot]
- 依赖包管理器：[例如：NuGet | pnpm / npm | pip | go mod]

## 2. 验证与构建命令 (能力声明：从真实入口读取，无命令填 NONE)
- 编译构建入口：[例如：dotnet build | npm run build | NONE]
- 自动化测试入口：[例如：dotnet test | npm test | NONE]
- 替代验证探针：[若无自动化测试，指定接口探针或验证脚本入口，如：python verify_api.py | NONE]
- 本地启动入口：[例如：dotnet run | npm run dev | NONE]

## 3. 产物与隔离红线 (必须明确具体路径)
- 产物身份与隔离：[记录 DLL、Bundle 或可执行文件哈希；服务验证须绑定已加载产物与启动命令，独立指定输出目录，严禁中间产物散落源码树]
- 绝对禁止改动的目录：[例如：/deploy/cert/ | /legacy-api/ | NONE]
- 敏感与环境配置文件：[例如：本地允许改动 appsettings.Development.json，严禁碰 appsettings.Production.json]

## 4. 架构与依赖硬性约定
- 引入新依赖库权限：[禁止私自引入，必须沿用现有库 | 允许常规无风险开源库]
- 接口兼容性底线：[对外接口必须保持向下兼容 | 允许版本升级破坏性重构]
- 架构变更禁令：[例如：严禁擅自新建独立服务，必须沿用现有插件体系 | NONE]
- 代码命名与风格：[例如：异步方法必带 Async 后缀 | 遵循仓库既有风格]
