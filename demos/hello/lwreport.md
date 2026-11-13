# lazarusWeb 转换报告

生成时间: 2026-11-10 08:15:45
源工程  : `C:\lazarusWeb\demos\hello`
输出目录: ``
转换器  : lwconvert 2.1

## 一、源码改写

（没有需要改写的行）

## 二、窗体注册顺序（第一个是默认窗体）

（没有找到 Application.CreateForm —— 请手工在 .lpr 里加 TLWApp.Register）

## 三、控件支持度

### uHello.lfm

| 控件类 | 数量 | 支持度 |
|---|---:|---|
| TLabel | 3 | 未收录 |
| TEdit | 1 | 未收录 |
| TCheckBox | 1 | 未收录 |
| TComboBox | 1 | 未收录 |
| TButton | 1 | 未收录 |
| TMemo | 1 | 未收录 |

> 这些类不在支持矩阵里 / 只做占位：TLabel,TEdit,TCheckBox,TComboBox,TButton,TMemo

共 1 个窗体、8 个控件实例；1 个窗体含未完整支持的控件。

## 四、警告与待办

无。

## 五、编译与运行

```bat
lazbuild -B --ws=nogui \.lpi
```

