# lazarusWeb
编译环境：  
1、fpc trunk  
2、lazarus 4.8  
2026-11-08周日闲来无事，让AI整了个Lazarus 桌面程序的 Web 化运行， 参考 uniGUI 的思路，但用真实的 LCL 控件树直接序列化成Alpine.js界面。业务程序只需要把窗体基类从 TForm 改成 TLWForm，其余代码（事件、属性、.lfm）原样保留，就能以服务程序的形式跑在浏览器里。  
这个在内网使用还是可以的，方便只会写lazarus普通桌面应用人，如果不使用第三方可视控件，可以很简单就可以转为Web应用。  
lazarusWeb默认使用Alpine.js，也可以使用Ext js  
# 特别说明：这个框架肯定有很多问题，只能用来验证lazarus桌面程序快速转为Web应用的可能和效果。  
<img width="1879" height="1277" alt="QQ_2026-11-12_10-00-49" src="https://github.com/user-attachments/assets/5d491f53-0752-4eb3-8f02-be63c46e3fc4" />
<img width="1840" height="1185" alt="QQ_2026-11-12_10-01-14" src="https://github.com/user-attachments/assets/5825dcfc-f786-458e-b54f-522d1488f5a4" />
<img width="1825" height="1180" alt="QQ_2026-11-12_10-01-51" src="https://github.com/user-attachments/assets/ad10f597-bd4b-4b31-969b-7372a997715c" />
<img width="1866" height="1183" alt="QQ_2026-11-12_10-02-09" src="https://github.com/user-attachments/assets/e3f15d71-38e9-4c88-b432-d71c7b952702" />
<img width="1847" height="1188" alt="QQ_2026-11-12_10-07-21" src="https://github.com/user-attachments/assets/efdf4e8c-9740-40d7-9f9e-2054bfb98f16" />
<img width="1851" height="1197" alt="QQ_2026-11-12_10-07-43" src="https://github.com/user-attachments/assets/687862cd-4041-4f46-a393-707ed1bd15ba" />
<img width="1832" height="1189" alt="QQ_2026-11-12_10-07-59" src="https://github.com/user-attachments/assets/f5fac17d-2bfc-4b00-a402-88b11e2b3f10" />
<img width="1814" height="1180" alt="QQ_2026-11-12_10-08-16" src="https://github.com/user-attachments/assets/05b32887-eaa8-4a95-bb19-1f7b6833d8af" />
<img width="1821" height="1174" alt="QQ_2026-11-12_10-08-34" src="https://github.com/user-attachments/assets/2af69890-6d88-4697-aa17-f9b31520a5d0" />
<img width="1815" height="1174" alt="QQ_2026-11-12_10-08-58" src="https://github.com/user-attachments/assets/0c056798-9033-4624-b9f6-86f110ff6a06" />
