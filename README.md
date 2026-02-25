# 斗地主原型（Supabase，非 Google 依赖）

单文件前端：`index.html`

- 房间人数上限：9
- 对局人数：2-4（其余可围观）
- 登录方式：Supabase Anonymous Auth（无感登录）
- 数据存储：Supabase Postgres
- 同步方式：Realtime 订阅 + 轮询兜底

## 1. 在 Supabase 创建项目

1. 打开 Supabase 控制台，新建项目。
2. 在 `Project Settings -> API` 获取：
   - `Project URL`
   - `Publishable API key`（推荐）

## 2. 启用匿名登录

路径：`Authentication -> Providers -> Anonymous Sign-Ins`，开启 `Enable`。

## 3. 初始化数据库

在 Supabase 的 `SQL Editor` 执行 [supabase.schema.sql](/Users/xl/Documents/doudizhu/supabase.schema.sql)。

这会创建：
- `rooms`
- `private_hands`
- RLS 策略
- Realtime 发布表

## 4. 填写前端配置

编辑 [index.html](/Users/xl/Documents/doudizhu/index.html)，替换：

```js
const supabaseConfig = {
  url: "REPLACE_ME",
  publishableKey: "REPLACE_ME"
};
```

## 5. 配置授权域名

路径：`Authentication -> URL Configuration`，补充：
- `http://localhost:8000`（本地）
- `https://你的用户名.github.io`
- 如果是仓库页地址也可加：`https://你的用户名.github.io/你的仓库名`

## 6. 本地测试

```bash
cd /Users/xl/Documents/doudizhu
python3 -m http.server 8000
```

浏览器打开 `http://localhost:8000`。

## 7. 发布 GitHub Pages

1. 提交并推送仓库。
2. GitHub `Settings -> Pages`
3. `Deploy from a branch`，选 `main / (root)`。

## 8. 玩法说明（原型）

当前只实现单牌比较：

- 2-4 人入座并准备后，房主开始
- 叫分确定地主
- 地主拿底牌
- 轮流出单牌，需大于上一手（新轮次可任意）
- 先出完牌者获胜

## 9. 安全边界

这是原型级别：
- 手牌默认仅本人可读，房主可写（发牌）
- 房间状态靠版本号（`revision`）CAS 更新避免并发覆盖
- 并非强对抗防作弊版本

如需强抗作弊，建议升级为“服务端权威裁决”（Edge Function/自建后端）。
