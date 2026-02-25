# 斗地主原型（Firebase Realtime Database）

单文件原型：`index.html`

- 房间人数上限：9
- 对局人数：3（其余可在房间内围观）
- 登录方式：Firebase Anonymous Auth（无感登录）
- 数据：Firebase Realtime Database
- 反作弊基础：
  - 手牌放在 `privateHands/{roomId}/{uid}`，默认只有本人可读
  - 关键流程（入座、准备、叫分、回合推进）使用事务
  - 房主负责发牌与底牌发放，避免多端并发冲突

## 1. Firebase 配置

1. 在 Firebase Console 创建项目。
2. 开启 **Authentication -> Anonymous**。
3. 创建 **Realtime Database**。
4. 将 `firebase.rules.json` 的内容发布到 Realtime Database Rules。
5. 在 `index.html` 里替换 `firebaseConfig` 的 `REPLACE_ME` 字段。

## 2. 本地测试

直接用静态服务器打开，例如：

```bash
npx serve .
```

## 3. 发布到 GitHub Pages

1. 把 `index.html`、`firebase.rules.json`、`README.md` 提交到仓库。
2. 在仓库 `Settings -> Pages` 选择分支（如 `main` / root）。
3. 打开 Pages 地址即可使用。

## 4. 规则说明

当前是“可运行原型”级别规则，重点保护手牌私密性。若你需要更强抗作弊（如服务端裁决每一步合法性），建议再加 Cloud Functions 做权威判定。

## 5. 玩法说明（原型）

当前只实现了**单牌比较**，用于快速验证多人联机与流程：

- 3 人入座并准备后，房主开始
- 叫分后确定地主
- 地主领取底牌
- 按回合出单牌，需大于上一手（新轮次可任意）
- 先出完牌者获胜
