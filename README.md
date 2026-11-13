# lazarusWeb
编译环境：  
1、fpc trunk  
2、lazarus 4.8  
2026-11-08周日闲来无事，让AI写了个Lazarus 桌面程序的 Web 化运行， 参考 uniGUI 的思路，但用真实的 LCL 控件树直接序列化成Alpine.js界面。业务程序只需要把窗体基类从 TForm 改成 TLWForm，其余代码（事件、属性、.lfm）原样保留，就能以服务程序的形式跑在浏览器里。  
这个在内网使用还是可以的，方便只会写lazarus普通桌面应用的人，如果不使用第三方可视控件，可以很简单就可以转为Web应用。  
lazarusWeb默认使用Alpine.js(已自带在src/client/alpine.min.js)，也可以选择Ext js  
# 特别说明：这个框架肯定有很多问题，只能用来验证lazarus桌面程序快速转为Web应用的可能和效果。  
<img width="1817" height="1176" alt="QQ_2026-11-13_11-10-07" src="https://github.com/user-attachments/assets/87dd6d96-f620-44f7-87b4-59058432f7a4" />
<img width="1845" height="1269" alt="QQ_2026-11-12_17-11-14" src="https://github.com/user-attachments/assets/2f6bb2ff-cae0-4177-b82e-1032c1663d2c" />
<img width="1821" height="1179" alt="QQ_2026-11-12_17-11-33" src="https://github.com/user-attachments/assets/6cf0fb0d-6586-470a-94ca-04641d33620e" />
<img width="1815" height="1170" alt="QQ_2026-11-12_17-11-48" src="https://github.com/user-attachments/assets/305a37e0-0fae-4fb5-b123-fa741f96c0b5" />
<img width="1815" height="1179" alt="QQ_2026-11-12_17-12-04" src="https://github.com/user-attachments/assets/c3ccde1f-ddb7-4089-8073-978f3d0dacaa" />
<img width="1815" height="1184" alt="QQ_2026-11-12_17-12-21" src="https://github.com/user-attachments/assets/5748a74a-e25f-4aed-b3d5-fc23327430b8" />
<img width="1815" height="1173" alt="QQ_2026-11-12_17-12-38" src="https://github.com/user-attachments/assets/54d084f1-e637-4b60-a2ed-7b5f97cccd4f" />
<img width="1809" height="1177" alt="QQ_2026-11-12_17-13-01" src="https://github.com/user-attachments/assets/7fbe0270-3a95-424a-8c35-24fc87f50a05" />
<img width="1815" height="1179" alt="QQ_2026-11-12_17-17-44" src="https://github.com/user-attachments/assets/92e18df9-9ca7-4565-9b78-1e73260f254c" />
<img width="1817" height="1179" alt="QQ_2026-11-12_17-18-11" src="https://github.com/user-attachments/assets/8b8df772-352e-43ad-97e9-f559cfc02b66" />
<img width="1824" height="1173" alt="QQ_2026-11-13_09-15-53" src="https://github.com/user-attachments/assets/90ca9690-cba7-48da-bb30-1cefebaad4d1" />
<img width="1759" height="879" alt="QQ_2026-11-13_10-08-28" src="https://github.com/user-attachments/assets/0f540f1a-aebb-4da4-b424-8cc69730996f" />
<img width="1035" height="826" alt="QQ_2026-11-13_10-09-08" src="https://github.com/user-attachments/assets/a4c7a490-adfd-4be1-b25c-7f2e652133fe" />
