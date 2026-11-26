{
  SPDX-License-Identifier: MIT  (c) 2026 szlbz(秋风) QQ:315795176 -- 见仓库根目录 LICENSE
  lazarusWeb :: lwdispatch
  ------------------------------------------------------------------
  浏览器事件 -> 真实 LCL 控件事件。

  流程（与 uniGUI 的服务端事件模型对齐）：
    1. 浏览器把 id / ev / val / row / col 发到 /lw/api/event；
    2. 服务端按 id 找回 LCL 控件；
    3. 先把浏览器上的新值写回控件属性（Edit.Text / CheckBox.Checked / Grid.Cells…），
       这样 OnChange 里读到的一定是用户刚输入的内容；
    4. 通过 RTTI 取到 OnClick/OnChange 之类的方法指针并调用 —— 业务代码完全不用改；
    5. 重新序列化整棵窗体树返回，浏览器做增量协调（reconcile），不会整页刷新。
}
unit lwdispatch;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, TypInfo, Forms, Controls, StdCtrls, ComCtrls, Grids,
  ExtCtrls, MaskEdit, Spin, Buttons, Graphics, DB, DBCtrls, DBGrids,
  InterfaceBase, fpjson, lwbase, lwsession, lwdbnav, lwdbgrid, lwlogin,
  CheckLst, ValEdit, EditBtn, lwui
  {$IFDEF LW_VIRTUALTREEVIEW}
  , lwvirtualtree, laz.virtualtrees
  {$ENDIF}
  ;

{ 处理一次事件，返回新的完整组件树；AErr 非空表示出错 }
function LWHandleEvent(S: TLWSession; AReq: TJSONObject; out AErr: string): TJSONObject;

{ 把浏览器值写回 LCL 控件 }
procedure LWApplyValue(C: TComponent; AReq: TJSONObject);
{ 把浏览器点击的行列写回 Grid，让 OnClick 里的 Grid.Row 是用户真正点到的那行 }
procedure LWApplyGridPos(C: TComponent; AReq: TJSONObject);
{ TDBGrid 单元格编辑：把浏览器的值写进数据集（Edit + Post）。
  Post 走数据集缓存，落库仍由业务代码 ApplyUpdates/Commit —— 与桌面 LCL 一致 }
procedure LWApplyDBGridEdit(C: TComponent; AReq: TJSONObject);
{ TCheckGroup.OnItemClick 是 (Sender; Index) 两参事件，必须类型化调用 }
procedure LWApplyCheckGroupClick(C: TComponent; AReq: TJSONObject);
{ TValueListEditor.OnValidate 是 (Sender; ACol; ARow; KeyName; KeyValue) 五参事件 }
procedure LWApplyVLEValidate(C: TComponent; AReq: TJSONObject);
{ 触发控件上的某个事件方法 }
function LWInvokeEvent(C: TComponent; const AEv: string; ARow, ACol: Integer): Boolean;

{ ISO 串 -> TDateTime（'yyyy-mm-dd' / 'hh:nn:ss' / 'yyyy-mm-dd hh:nn:ss'，
  也接受浏览器 datetime-local 的 'yyyy-mm-ddThh:nn:ss'）。解析失败返回 ADef }
function LWISOToDateTime(const S: string; ADef: TDateTime): TDateTime;

{ ---------------- 值回写登记表（第三方控件用） ----------------

  内建回写是一条写死的 if 链（TEdit / TComboBox / TDateEdit …），第三方控件
  没法在外面接进来。这里开一张登记表：单元在自己的 initialization 里登记
  一次，LWApplyValue 就会先问这张表，命中即由登记方自己写控件。

  为什么需要：DateTimeCtrls 的 TDateTimePicker 只有 DateTime/Date/Time 属性，
  写 Text 无效；核心包又不依赖 DateTimeCtrls（与 VirtualTreeView 同策），
  所以桥接放在 lwdatetime.pas 里，由用到它的工程 uses。

  匹配规则与 LWRegisterControlKind 一致：沿继承链从最派生往祖先找，
  第一个登记过的类胜出。登记必须发生在第一批请求之前（Run 之前）。 }

type
  TLWValueWriterProc = procedure(C: TComponent; const S: string);

procedure LWRegisterValueWriter(AClass: TClass; AProc: TLWValueWriterProc);
{ 查 C 命中哪个登记的回写器；未登记返回 nil }
function LWRegisteredValueWriter(C: TComponent): TLWValueWriterProc;

implementation

{ ---------------- 值回写登记表（第三方控件用） ---------------- }

type
  PLWValueWriter = ^TLWValueWriter;
  TLWValueWriter = record
    Cls: TClass;
    Proc: TLWValueWriterProc;
    Next: PLWValueWriter;
  end;

var
  GLwValueHead: PLWValueWriter = nil;

procedure LWRegisterValueWriter(AClass: TClass; AProc: TLWValueWriterProc);
var
  e: PLWValueWriter;
begin
  if (AClass = nil) or (AProc = nil) then Exit;
  New(e);
  e^.Cls := AClass;
  e^.Proc := AProc;
  { 头插。登记只在 Run 之前发生（单线程），读者要么看到空表，
    要么看到一条字段已写完的完整节点；节点永不释放，所以无需加锁 }
  e^.Next := GLwValueHead;
  GLwValueHead := e;
end;

function LWRegisteredValueWriter(C: TComponent): TLWValueWriterProc;
var
  p: TClass;
  e: PLWValueWriter;
begin
  Result := nil;
  if (C = nil) or (GLwValueHead = nil) then Exit;
  p := C.ClassType;
  while p <> nil do
  begin
    e := GLwValueHead;
    while e <> nil do
    begin
      if e^.Cls = p then
      begin
        Result := e^.Proc;
        Exit;
      end;
      e := e^.Next;
    end;
    p := p.ClassParent;
  end;
end;

{ ISO 串 -> TDateTime。浏览器端统一回传 'yyyy-mm-dd' / 'hh:nn:ss'
  （日期+时间则 'yyyy-mm-dd hh:nn:ss'），与本地化格式无关。
  解析失败保持原值（ADef），不抛异常 }
function LWISOToDateTime(const S: string; ADef: TDateTime): TDateTime;
var
  dp, tp, tmp: string;
  dt, tm: TDateTime;
  y, mo, d, h, mi, se: Integer;
  okd, okt, hasd, hast: Boolean;
  sp: Integer;

  { 取前导整数并吃掉分隔符；不是数字返回 -1 }
  function TakeInt(var st: string; sep: Char): Integer;
  var
    p: Integer;
    tok: string;
  begin
    Result := -1;
    if st = '' then Exit;
    p := Pos(sep, st);
    if p > 0 then
    begin
      tok := Copy(st, 1, p - 1);
      st := Copy(st, p + 1, MaxInt);
    end
    else
    begin
      tok := Trim(st);
      st := '';
    end;
    if tok = '' then Exit;
    Result := StrToIntDef(tok, -1);
  end;

begin
  Result := ADef;
  if S = '' then Exit;
  tmp := Trim(S);
  { 浏览器原生 datetime-local 控件回传 'yyyy-mm-ddThh:nn:ss'，
    把 T 当空格看，其余解析路径不变 }
  sp := Pos('T', tmp);
  if (sp = 0) then sp := Pos('t', tmp);
  if (sp > 1) and (Pos(':', Copy(tmp, 1, sp - 1)) = 0) then
    tmp[sp] := ' ';
  { datetime-local 带小数秒时形如 '...:ss.123'，秒之后的部分不要 }
  sp := Pos('.', tmp);
  if sp > 0 then tmp := Copy(tmp, 1, sp - 1);
  sp := Pos(' ', tmp);
  if sp > 0 then
  begin
    dp := Copy(tmp, 1, sp - 1);
    tp := Trim(Copy(tmp, sp + 1, MaxInt));
  end
  else if Pos(':', tmp) > 0 then
  begin
    dp := '';
    tp := tmp;
  end
  else
  begin
    dp := tmp;
    tp := '';
  end;

  { 关键：dp/tp 会作为 var 实参传给 TakeInt，解析后必然被消费成空串，
    所以"是否提供了该部分"的标志必须在解析之前快照下来，
    不能直接拿 dp/tp 做判断（否则所有成功解析都会掉进 Result := ADef） }
  hasd := dp <> '';
  hast := tp <> '';
  okd := hasd;
  okt := hast;
  dt := ADef;
  tm := ADef;
  if okd then
  begin
    y := TakeInt(dp, '-');
    mo := TakeInt(dp, '-');
    d := TakeInt(dp, '-');
    okd := (y >= 1) and (mo >= 1) and (mo <= 12) and (d >= 1) and (d <= 31);
    if okd then
      okd := TryEncodeDate(y, mo, d, dt);
  end;
  if okt then
  begin
    h := TakeInt(tp, ':');
    mi := TakeInt(tp, ':');
    se := TakeInt(tp, ':');
    okt := (h >= 0) and (h < 24) and (mi >= 0) and (mi < 60) and (se >= 0) and (se <= 61);
    if okt then
      okt := TryEncodeTime(h, mi, se, 0, tm);
  end;

  { 只在"提供了该部分但解析失败"时拒绝；纯时间串没有日期部分、
    纯日期串没有时间部分，都是合法输入 }
  if hasd and (not okd) then
    Exit;
  if hast and (not okt) then
    Exit;
  if hasd and (not hast) then
    Result := dt
  else if (not hasd) and hast then
    Result := tm
  else if hasd and hast then
    Result := dt + tm
  else
    Result := ADef;
end;

{ 取 DB 控件的绑定字段 }
function LWDBFieldOf(C: TComponent): TField;
begin
  Result := nil;
  if C is TDBEdit then
    Result := TDBEdit(C).Field
  else if C is TDBMemo then
    Result := TDBMemo(C).Field
  else if C is TDBCheckBox then
    Result := TDBCheckBox(C).Field
  else if C is TDBComboBox then
    Result := TDBComboBox(C).Field
  else if C is TDBListBox then
    Result := TDBListBox(C).Field
  else if C is TDBLookupListBox then
    Result := TDBLookupListBox(C).Field
  else if C is TDBRadioGroup then
    Result := TDBRadioGroup(C).Field
  else if C is TDBLookupComboBox then
    Result := TDBLookupComboBox(C).Field;
end;

{ 浏览器上的新值写进数据集字段。

  注意不要写成 TDBEdit.Text := AVal：LCL 的 TDBEdit 只有在
  DataLink.Editing 为真时才会把 Text 推回字段，而 Editing 是由
  键盘消息（KeyDown -> DataLink.Edit）触发的 —— nogui 下没有键盘消息。
  这里直接对字段赋值，控件会通过 DataChange 自动同步显示。 }
procedure LWDBWrite(C: TComponent; const AVal: string);
var
  f: TField;
  ds: TDataSet;
begin
  f := LWDBFieldOf(C);
  if f = nil then Exit;
  ds := f.DataSet;
  if (ds = nil) or (not ds.Active) then Exit;
  if not (ds.State in [dsEdit, dsInsert]) then
    try
      ds.Edit;
    except
      Exit;
    end;
  if not (ds.State in [dsEdit, dsInsert]) then Exit;
  try
    if C is TDBCheckBox then
      f.AsBoolean := (AVal = '1') or SameText(AVal, 'true')
    else if f is TFloatField then
      { 列头设了 DisplayFormat 之后显示值会带千分位（"1,234.50"），
        直接 AsString 赋回去解析不了，这里先洗一遍 }
      f.AsFloat := StrToFloatDef(StringReplace(AVal, FormatSettings.ThousandSeparator, '',
        [rfReplaceAll]), f.AsFloat)
    else if f is TIntegerField then
      f.AsInteger := StrToIntDef(StringReplace(AVal, FormatSettings.ThousandSeparator, '',
        [rfReplaceAll]), f.AsInteger)
    else if f is TLargeIntField then
      f.AsLargeInt := StrToInt64Def(StringReplace(AVal, FormatSettings.ThousandSeparator, '',
        [rfReplaceAll]), f.AsLargeInt)
    else
      f.AsString := AVal;
  except
    { 类型不匹配（例如往整数字段写字母）就静默丢弃，
      数据集的旧值保持不变 —— 浏览器端下次协调会把它改回来 }
  end;
end;

{ CSS 颜色（#rrggbb）-> TColor。TColor 的低 24 位是 $00BBGGRR }
function CSSColorToTColor(const S: string; ADef: TColor): TColor;
var
  v: Integer;
begin
  Result := ADef;
  if (Length(S) = 7) and (S[1] = '#') then
  begin
    v := StrToIntDef('$' + Copy(S, 6, 2) + Copy(S, 4, 2) + Copy(S, 2, 2), -1);
    if v >= 0 then
      Result := TColor(v);
  end;
end;

procedure LWApplyValue(C: TComponent; AReq: TJSONObject);
var
  d, d2: TJSONData;
  s: string;
  idx, row, col, i: Integer;
  w: TLWValueWriterProc;
begin
  if (C = nil) or (AReq = nil) then Exit;
  d := AReq.Find('val');
  if d = nil then Exit;
  { val 应该是标量；客户端 bug 发来对象/数组时回默认，别抛 EJSON
    把整个事件处理打断（坑 142） }
  if not (d.JSONType in [jtString, jtNumber, jtBoolean]) then Exit;
  s := d.AsString;

  { 第三方登记的回写优先：命中后由登记方自己写控件（TDateTimePicker 等）。
    放在最前面是为了避开下面那些类型强转 —— 登记的是"内建链认不出的类" }
  if GLwValueHead <> nil then
  begin
    w := LWRegisteredValueWriter(C);
    if Assigned(w) then
    begin
      try
        w(C, s);
      except
        { 第三方回写抛异常也不能打断事件派发（OnChange 还要照常触发） }
      end;
      Exit;
    end;
  end;

  { TPageControl：浏览器把切换后的页签序号回传，服务端跟着切。
    不写这条的话服务端 ActivePage 永远停在初始页 —— 业务在 OnChange
    里读 ActivePage 拿到的是错的页（gallery 的"切到页签：标准控件"） }
  if C is TPageControl then
  begin
    idx := StrToIntDef(s, -1);
    if (idx >= 0) and (idx < TPageControl(C).PageCount) then
      TPageControl(C).ActivePage := TPageControl(C).Pages[idx];
    Exit;
  end;

  { TTabControl：与 TPageControl 同语义 —— 浏览器回传切换后的页签序号，
    服务端同步 TabIndex。缺这条的话 tabctl 页签切不动（视觉与业务都停在旧页），
    且 OnChange 处理器读 TabIndex 拿到的是旧值 }
  if C is TTabControl then
  begin
    idx := StrToIntDef(s, -1);
    if (idx >= 0) and (idx < TTabControl(C).Tabs.Count) then
      TTabControl(C).TabIndex := idx;
    Exit;
  end;

  { TDateEdit / TTimeEdit：浏览器回传的是统一 ISO 串（见 lwwriter 的 iso）。
    直接写 Date/Time，控件显示由 LCL 自己刷新 }
  if C is TDateEdit then
  begin
    TDateEdit(C).Date := LWISOToDateTime(s, TDateEdit(C).Date);
    Exit;
  end;
  if C is TTimeEdit then
  begin
    TTimeEdit(C).Time := LWISOToDateTime(s, TTimeEdit(C).Time);
    Exit;
  end;

  { 取色器：浏览器回传 #rrggbb }
  if C is TLWColorPicker then
  begin
    TLWColorPicker(C).Color := CSSColorToTColor(s, TLWColorPicker(C).Color);
    Exit;
  end;

  { TDBListBox：浏览器送的是"列表第几项"，不是文本。
    先同步 ItemIndex（业务代码 OnChange 里能读到），再把该行文本写进字段。 }
  if C is TDBListBox then
  begin
    idx := StrToIntDef(s, -1);
    if (idx >= 0) and (idx < TDBListBox(C).Items.Count) then
    begin
      TDBListBox(C).ItemIndex := idx;
      LWDBWrite(C, TDBListBox(C).Items[idx]);
    end;
    Exit;
  end;

  { TDBLookupComboBox：浏览器送的是 KeyField 的值。
    注意不能只写 KeyValue —— LCL 的 SetKeyValue 实现是
    `ItemIndex := GetKeyIndex(...)`，只改"选中第几行"，真正写字段依赖
    焦点/键盘消息链（nogui 下没有）。所以直接写 DataField（就是键字段），
    控件显示的 ListField 文本由 DataChange 自动跟上。 }
  if C is TDBLookupComboBox then
  begin
    LWDBWrite(C, s);
    Exit;
  end;

  { TDBLookupListBox：浏览器送的是 KeyField 的值，直接写 DataField }
  if C is TDBLookupListBox then
  begin
    LWDBWrite(C, s);
    Exit;
  end;

  { TDBRadioGroup：浏览器送的是被选中项的 Value（不是序号）}
  if C is TDBRadioGroup then
  begin
    idx := TDBRadioGroup(C).Values.IndexOf(s);
    if idx >= 0 then
      TDBRadioGroup(C).ItemIndex := idx;
    LWDBWrite(C, s);
    Exit;
  end;

  { TRadioGroup：浏览器送的是"第几项"（与 TDBRadioGroup 的 Value 语义不同）}
  if C is TRadioGroup then
  begin
    idx := StrToIntDef(s, -1);
    if (idx >= 0) and (idx < TRadioGroup(C).Items.Count) then
      TRadioGroup(C).ItemIndex := idx;
    Exit;
  end;

  { TUpDown：浏览器端上下箭头回传新位置。LCL 的 Associate 联动依赖
    Windows 消息链（nogui 下没有），所以这里手动把文本写进配对的编辑框 }
  if C is TUpDown then
  begin
    idx := StrToIntDef(s, TUpDown(C).Position);
    if idx < TUpDown(C).Min then idx := TUpDown(C).Min;
    if (TUpDown(C).Max > 0) and (idx > TUpDown(C).Max) then idx := TUpDown(C).Max;
    TUpDown(C).Position := idx;
    if (TUpDown(C).Associate <> nil) and (TUpDown(C).Associate is TCustomEdit) then
      TCustomEdit(TUpDown(C).Associate).Text := IntToStr(idx);
    Exit;
  end;

  { TCheckGroup：优先用浏览器回传的 checked 布尔数组逐项套用；
    数组缺席（事件只带 idx+val，两个客户端的历史行为都这样）时退化为
    单项写回 —— val 是该复选框的新状态（'1'/'0' 或 true/false），
    保证业务代码 OnItemClick 里读 Checked[i] 拿到的是用户刚点的值 }
  if C is TCheckGroup then
  begin
    d2 := AReq.Find('checked');
    if d2 is TJSONArray then
    begin
      for i := 0 to TCheckGroup(C).Items.Count - 1 do
        if i < TJSONArray(d2).Count then
          TCheckGroup(C).Checked[i] := TJSONArray(d2).Booleans[i];
      Exit;
    end;
    idx := JGetInt(AReq, 'idx', -1);
    if (idx >= 0) and (idx < TCheckGroup(C).Items.Count) then
      TCheckGroup(C).Checked[idx] := (s = '1') or SameText(s, 'true');
    Exit;
  end;

  { TCheckListBox：val 是选中项序号，checked 数组逐项套用 }
  if C is TCheckListBox then
  begin
    idx := StrToIntDef(s, -1);
    if (idx >= 0) and (idx < TCheckListBox(C).Items.Count) then
      TCheckListBox(C).ItemIndex := idx;
    d2 := AReq.Find('checked');
    if d2 is TJSONArray then
      for i := 0 to TCheckListBox(C).Items.Count - 1 do
        if i < TJSONArray(d2).Count then
          TCheckListBox(C).Checked[i] := TJSONArray(d2).Booleans[i];
    Exit;
  end;

  { TListBox：浏览器端点行回传的是项文本 —— 回写 ItemIndex，
    这样 OnClick/OnSelect 处理器里读 ItemIndex/GetSelectedText
    拿到的才是用户刚点的那行（实测点"香蕉"不能再记成"苹果"）。
    兼容旧调用方直接传序号（回归测试 val="1"）：文本找不到时按数字解释 }
  if C is TListBox then
  begin
    idx := TListBox(C).Items.IndexOf(s);
    if idx < 0 then
      idx := StrToIntDef(s, -1);
    if idx >= 0 then
      TListBox(C).ItemIndex := idx;
    Exit;
  end;

  { TValueListEditor：setval_key/setval_value 按键名改值；
    selrow 是选中行（0 起，不含标题行） }
  if C is TValueListEditor then
  begin
    row := JGetInt(AReq, 'selrow', -1);
    if (row >= 0) and (row < TValueListEditor(C).Strings.Count) then
      TValueListEditor(C).Row := row + 1;
    s := JGetStr(AReq, 'setval_key');
    if s <> '' then
    begin
      idx := TValueListEditor(C).Strings.IndexOfName(s);
      if idx >= 0 then
        TValueListEditor(C).Values[s] := JGetStr(AReq, 'setval_value');
    end;
    Exit;
  end;

  if LWDBFieldOf(C) <> nil then
  begin
    LWDBWrite(C, s);
    Exit;
  end;

  if C is TEdit then
    TEdit(C).Text := s
  else if C is TMaskEdit then
    TMaskEdit(C).Text := s
  else if C is TMemo then
    TMemo(C).Lines.Text := s
  else if C is TCheckBox then
    TCheckBox(C).Checked := (s = '1') or SameText(s, 'true')
  else if C is TRadioButton then
    TRadioButton(C).Checked := (s = '1') or SameText(s, 'true')
  else if C is TComboBox then
  begin
    idx := TComboBox(C).Items.IndexOf(s);
    if idx >= 0 then
    begin
      TComboBox(C).ItemIndex := idx;
      TComboBox(C).Text := s;
    end
    else
      TComboBox(C).Text := s;
  end
  else if C is TListBox then
  begin
    idx := StrToIntDef(s, -1);
    if (idx >= 0) and (idx < TListBox(C).Items.Count) then
      TListBox(C).ItemIndex := idx;
  end
  else if C is TSpinEdit then
    TSpinEdit(C).Value := StrToIntDef(s, TSpinEdit(C).Value)
  else if C is TFloatSpinEdit then
    { TFloatSpinEdit 与 TSpinEdit 是兄弟类（都继承 TCustomSpinEdit），
      必须单独分支 —— 缺这条的话 floatspin 的值全部被丢弃 }
    TFloatSpinEdit(C).Value := StrToFloatDef(s, TFloatSpinEdit(C).Value)
  else if C is TStringGrid then
  begin
    { 浏览器只送数据行序号（不含固定行），这里加回 FixedRows }
    row := JGetInt(AReq, 'row', -1);
    col := JGetInt(AReq, 'col', -1);
    if row >= 0 then
      Inc(row, TStringGrid(C).FixedRows);
    if (row >= 0) and (col >= 0) and (row < TStringGrid(C).RowCount) and
      (col < TStringGrid(C).ColCount) then
      TStringGrid(C).Cells[col, row] := s;
  end
  else if C is TProgressBar then
    TProgressBar(C).Position := StrToIntDef(s, TProgressBar(C).Position)
  else if C is TTrackBar then
    TTrackBar(C).Position := StrToIntDef(s, TTrackBar(C).Position)
  else if C is TCustomEdit then
    { TCustomEdit 兜底：TLabeledEdit / TCustomEditButton 族（editbtn：
      TFileNameEdit / TDirectoryEdit / TCustomEditButton）等都是
      TCustomEdit 子类而非 TEdit 子类 —— 缺这条的话这些控件的 Text
      回写全部落空（writer 照发 OnChange val，服务端没有分支接） }
    TCustomEdit(C).Text := s;
end;

procedure LWApplyGridPos(C: TComponent; AReq: TJSONObject);
var
  row, col: Integer;
  ds: TDataSet;
  lwg: TLWDBGrid;
  idx: Integer;
begin
  { TDBGrid：浏览器点的是"第几行数据"，直接定位数据集游标，
    与该行绑定的 DBEdit 会跟着刷新。
    TLWDBGrid（分页/过滤）：row 是"当前页/过滤结果里的第几行"，
    用 writer 序列化时留下的匹配书签表映射回真实记录；
    书签失效（数据集重开等）时定位失败，保持原游标不动 }
  if C is TDBGrid then
  begin
    row := JGetInt(AReq, 'row', -1);
    if row < 0 then Exit;
    if (TDBGrid(C).DataSource = nil) or (TDBGrid(C).DataSource.DataSet = nil) then Exit;
    ds := TDBGrid(C).DataSource.DataSet;
    if not ds.Active then Exit;
    if C is TLWDBGrid then
    begin
      lwg := TLWDBGrid(C);
      if lwg.MatchCount > 0 then
      begin
        idx := row;
        if lwg.PageSize > 0 then
          Inc(idx, (lwg.CurrentPage - 1) * lwg.PageSize);
        if idx < lwg.MatchCount then
          try
            ds.GotoBookmark(lwg.MatchAt(idx));
          except
          end;
        Exit;
      end;
    end;
    try
      ds.RecNo := row + 1;
    except
    end;
    Exit;
  end;

  if not (C is TStringGrid) then
  begin
    { TValueListEditor：row 是数据行序号（0 起，不含标题行） }
    if C is TValueListEditor then
    begin
      row := JGetInt(AReq, 'row', -1);
      if (row >= 0) and (row < TValueListEditor(C).Strings.Count) then
        TValueListEditor(C).Row := row + 1;
    end;
    { TListView：浏览器点的是"第几项"（val），同步选中项。
      注意必须用 Items[i].Selected := True 逐项置位：MultiSelect=True 时
      GetSelection 每次都按 Items[i].Selected 重算，直接赋 Selected 属性
      在 nogui 下会被冲掉（无 widget 状态）。 }
    if C is TListView then
    begin
      row := StrToIntDef(JGetStr(AReq, 'val'), -1);
      if (row >= 0) and (row < TListView(C).Items.Count) then
      begin
        TListView(C).ClearSelection;
        TListView(C).Items[row].Selected := True;
        TListView(C).ItemIndex := row;
      end;
    end;
    { TTreeView：val 是顶层节点的序号，选中后 OnClick 里读 Selected。
      nogui widgetset 没有 CreateTimer（返回 0 → EOutOfResources），而
      LCL TTreeView 的选中变化会启用内部的 FChangeTimer（TTimer）直接炸
      —— nogui 下先摘掉它拥有的 TTimer.OnTimer 再选中，代价是
      OnSelectionChanged 的延迟通知不触发（OnClick 不受影响）。 }
    if C is TTreeView then
    begin
      row := StrToIntDef(JGetStr(AReq, 'val'), -1);
      if (row >= 0) and (row < TTreeView(C).Items.Count) then
      begin
        { nogui 下以及 GUI 构建的代理 widgetset（lwproxyws）里，工作线程
          用的 widgetset 都没有 CreateTimer（返回 0 → EOutOfResources），而
          LCL TTreeView 选中变化会启用内部 FChangeTimer 直接 EOutOfResources
          —— 先摘掉它拥有的 TTimer.OnTimer 再选中，代价是 OnSelectionChanged
          的延迟通知不触发（OnClick 不受影响）。 }
        { 未加编译条件：nogui 与 GUI 构建下会话控件一律无头，行为一致 }
        for idx := 0 to C.ComponentCount - 1 do
          if C.Components[idx] is TTimer then
            TTimer(C.Components[idx]).OnTimer := nil;
        TTreeView(C).Selected := TTreeView(C).Items[row];
      end;
    end;
    { VirtualTreeView：val 是序列化时下发的节点路径（"0.1.2"），
      虚拟节点不能按扁平序号取，必须沿父子关系逐级定位 }
    {$IFDEF LW_VIRTUALTREEVIEW}
    if C is TBaseVirtualTree then
      LWVirtualTreeSelectByPath(TBaseVirtualTree(C), JGetStr(AReq, 'val'));
    {$ENDIF}
    Exit;
  end;
  row := JGetInt(AReq, 'row', -1);
  col := JGetInt(AReq, 'col', -1);
  if row >= 0 then
    Inc(row, TStringGrid(C).FixedRows);
  if (row >= 0) and (row < TStringGrid(C).RowCount) then
    TStringGrid(C).Row := row;
  if (col >= 0) and (col < TStringGrid(C).ColCount) then
    TStringGrid(C).Col := col;
end;

{ TDBGrid 单元格编辑：浏览器的 CellEditing 完成后发 OnSetFieldValue。
  调用前 LWApplyGridPos 已把数据集游标定位到被编辑的行（row 是 0 起
  的行号，与 OnCellClick 同一约定）。这里只做字段赋值 + Post：
  - Post 后数据集回 dsBrowse，writer 才会重发 rows，浏览器看到新值；
  - 落库交给业务代码（sqoAutoApplyUpdates 自动 ApplyUpdates，
    Commit 仍由保存按钮做），与桌面 LCL 的语义完全一致；
  - 只读网格 / 只读列 / 无字段列直接吞掉，不报错；
  - 赋值失败（如数字列填了字母）回滚 Cancel，不让会话挂掉。 }
procedure LWApplyDBGridEdit(C: TComponent; AReq: TJSONObject);
var
  G: TDBGrid;
  ds: TDataSet;
  f: TField;
  col: Integer;
  v: string;
  dtv: TDateTime;
begin
  if not (C is TDBGrid) then Exit;
  G := TDBGrid(C);
  if not (dgEditing in G.Options) then Exit;
  if (G.DataSource = nil) or (G.DataSource.DataSet = nil) then Exit;
  ds := G.DataSource.DataSet;
  if not ds.Active then Exit;

  col := JGetInt(AReq, 'col', -1);
  if (col < 0) or (col >= G.Columns.Count) then Exit;
  f := G.Columns[col].Field;
  if (f = nil) or f.ReadOnly or G.Columns[col].ReadOnly then Exit;

  v := JGetStr(AReq, 'val');
  try
    ds.Edit;
    try
      { 日期/时间字段：浏览器 date 选择器回传 ISO 'yyyy-mm-dd'，走
        AsString 会被区域设置的 StrToDateTime 解析（'-' 分隔符未必
        吃得下），这里先解析成 TDateTime 再赋 AsDateTime。
        TTimeField 也是 TDateTimeField 后代但吃的是时间串，排除掉。 }
      if ((f.ClassType = TDateTimeField) or (f is TDateField)) and (v <> '') then
      begin
        dtv := LWISOToDateTime(v, -1);
        if dtv < 0 then
        begin
          ds.Cancel;
          Exit;
        end;
        f.AsDateTime := dtv;
      end
      { 布尔字段：前端勾选框回传 '1'/'0'。AsString 走的是
        TBooleanField 的文本解析（认得的是它自己的 DisplayValues，
        未设时是 True/False），'1'/'0' 未必吃得下，直接转布尔 }
      else if f is TBooleanField then
        f.AsBoolean := (v = '1') or (SameText(v, 'true')) or (SameText(v, 'yes'))
      else
        f.AsString := v;
    except
      ds.Cancel;
      Exit;
    end;
    ds.Post;
  except
    try ds.Cancel; except end;
  end;
end;

{ TCheckGroup 的复选框点击：(Sender; Index) 两参，类型化调用。
  浏览器已把新 checked 状态放进请求（LWApplyValue 先套用），
  这里只负责触发业务代码的 OnItemClick。 }
procedure LWApplyCheckGroupClick(C: TComponent; AReq: TJSONObject);
var
  PP: PPropInfo;
  M: TMethod;
  idx: Integer;
begin
  if not (C is TCheckGroup) then Exit;
  PP := GetPropInfo(C, 'OnItemClick');
  if PP = nil then Exit;
  M := GetMethodProp(C, PP);
  if not Assigned(M.Code) then Exit;
  idx := JGetInt(AReq, 'idx', -1);
  TCheckGroupClicked(M)(C, idx);
end;

{ TValueListEditor 的值校验：五参 (Sender; ACol; ARow; KeyName; KeyValue)。
  ACol=1（值列）、ARow=数据行号+1（含标题行）；先把新值写进控件
  （与网格单元格编辑同语义：编辑完成即生效），再触发业务代码的
  OnValidate —— handler 里能读到已生效的新值。 }
procedure LWApplyVLEValidate(C: TComponent; AReq: TJSONObject);
var
  PP: PPropInfo;
  M: TMethod;
  row: Integer;
  key, val: string;
begin
  if not (C is TValueListEditor) then Exit;
  row := JGetInt(AReq, 'row', 0);
  key := JGetStr(AReq, 'key');
  val := JGetStr(AReq, 'val');
  { 只写已存在的键名，键名不存在（如浏览器乱传）直接忽略 }
  if (key <> '') and (TValueListEditor(C).Strings.IndexOfName(key) >= 0) then
    TValueListEditor(C).Values[key] := val;
  PP := GetPropInfo(C, 'OnValidate');
  if PP = nil then Exit;
  M := GetMethodProp(C, PP);
  if not Assigned(M.Code) then Exit;
  TOnValidateEvent(M)(C, 1, row + 1, key, val);
end;

{ 浏览器点击导航按钮 -> BtnClick。
  TDBNavigator.OnClick 的签名是 TDBNavClickEvent(Sender; Button) 两参，
  不能走 LWInvokeEvent 的通用 TNotifyEvent 调用；而且 LCL 的
  TDBCustomNavigator.BtnClick 内部会依次触发 BeforeAction -> 数据集动作
  -> OnClick，所以这里只调 BtnClick 一个入口就完整了。
  删除按钮带 ConfirmDelete=True 时会弹 MessageDlg —— nogui 下由
  lwdlg 的钩子改道到浏览器模态框，用户答复后服务端线程继续往下走。

  内建动作抛异常时不让它打断整个事件请求（否则表现成 500 / EWriteError，
  用户看到的就是"点了按钮没反应"）：
  - nbPost：网格单元格编辑在服务端已经 Edit+Post（回到 dsBrowse），
    内建 Post 必然抛 "not in edit or insert state" —— 用户的"保存"按钮
    看起来就坏了；改动其实早已进缓存。
  - nbRefresh：内存缓冲数据集（TBufDataset 系）抛
    "In-memory table cannot be refreshed"，应用往往在 OnClick 里自己实现
    刷新（重开数据集/换事务快照）。
  有 OnClick 时把异常记日志、继续触发 OnClick 让业务分支兜底；
  没有 OnClick 就把异常原样抛回（保持真实语义）。 }
procedure LWApplyDBNavClick(C: TComponent; AReq: TJSONObject);
var
  btn: TDBNavButtonType;
  nav: TDBNavigator;
begin
  if not (C is TDBNavigator) then Exit;
  if not LWNavBtnFromId(JGetStr(AReq, 'val'), btn) then Exit;
  nav := TDBNavigator(C);
  try
    nav.BtnClick(btn);
  except
    on E: Exception do
    begin
      if not Assigned(nav.OnClick) then
        raise;
      if LWCurrentSession <> nil then
        LWCurrentSession.SessionNotify(Format(
          'nav %s: 内建动作失败已忽略（%s: %s），交给 OnClick 处理',
          [LWNavBtnToId(btn), E.ClassName, E.Message]));
      nav.OnClick(nav, btn);
    end;
  end;
end;

function LWInvokeEvent(C: TComponent; const AEv: string; ARow, ACol: Integer): Boolean;
var
  PP: PPropInfo;
  M: TMethod;
  G: TDBGrid;
  col: TColumn;
begin
  Result := False;

  if (C = nil) or (AEv = '') then Exit;

  if not IsLWClickEvent(AEv) then Exit;

  { TDBGrid 的 OnTitleClick / OnCellClick 签名是 (Column: TColumn)，
    不是 TNotifyEvent，必须按真实类型调用 }
  if C is TDBGrid then
  begin
    G := TDBGrid(C);
    if (AEv = 'OnTitleClick') or (AEv = 'OnCellClick') then
    begin
      if (ACol >= 0) and (ACol < G.Columns.Count) then
        try
          G.SelectedIndex := ACol;
        except
        end;
      PP := GetPropInfo(G, AEv);
      if PP = nil then Exit;
      M := GetMethodProp(G, PP);
      if not Assigned(M.Code) then Exit;
      col := nil;
      if (G.SelectedIndex >= 0) and (G.SelectedIndex < G.Columns.Count) then
        col := TColumn(G.Columns[G.SelectedIndex]);
      TDBGridClickEvent(M)(col);
      Exit(True);
    end;
  end;

  { 按钮：走原生的 Click，而不是直接调 OnClick 方法指针。
    TCustomButton.Click 里有一句 "if ModalResult <> mrNone then
    Form.ModalResult := ModalResult"，这正是模态对话框点确定/取消后
    关闭窗体的机制 —— nogui 下没有消息循环，绕过 Click 就没人做这件事，
    ShowModal 会一直挂到超时。 }
  if (AEv = 'OnClick') and (C is TButton) then
  begin
    TButton(C).Click;
    Exit(True);
  end;
  if (AEv = 'OnClick') and (C is TBitBtn) then
  begin
    TBitBtn(C).Click;
    Exit(True);
  end;

  { TSpeedButton：点击 = 按下。GroupIndex>0 时 SetDown(True) 内部的
    UpdateExclusive 会自动弹起同组其它按钮（组互斥由 LCL 负责），
    Down 状态随后随快照下发，浏览器端恢复按下观感 }
  if (AEv = 'OnClick') and (C is TSpeedButton) and (TSpeedButton(C).GroupIndex > 0) then
    TSpeedButton(C).Down := True;

  PP := GetPropInfo(C, AEv);
  if (PP = nil) or (PP^.PropType^.Kind <> tkMethod) then Exit;
  M := GetMethodProp(C, PP);
  if not Assigned(M.Code) then Exit;
  TNotifyEvent(M)(C);
  Result := True;
end;

{ 快照里允许写回的控件类型。
  刻意排除数据库感知控件（TDBEdit / TDBMemo / TDBCheckBox ...）：
  它们背后是数据集字段，写 Text 等于改数据；这类控件走自己的
  编辑通道（OnSetFieldValue / 数据集的 Edit-Post），不能在这里乱写 }
function LWIsSnapField(C: TComponent): Boolean;
begin
  Result := (C is TEdit) or (C is TMemo) or (C is TComboBox) or
    (C is TCheckBox) or (C is TRadioButton) or (C is TSpinEdit) or
    (C is TFloatSpinEdit) or (C is TDateEdit) or (C is TTimeEdit);
  { 第三方登记的输入控件（TDateTimePicker 等）也要参与快照，
    否则点"保存"时读到的是旧值 }
  if (not Result) and (GLwValueHead <> nil) then
    Result := LWRegisteredValueWriter(C) <> nil;
end;

{ 浏览器在事件包里附带"同一窗体所有输入控件的当前值"。
  为什么需要它：lw.js 只有在控件挂了 OnChange 时才回传值，没挂的
  编辑框（比如登录窗体的用户名/密码）在服务端永远是构建时的初始
  Text —— 点"登录"时校验的是旧值，输错密码也能过。
  这里在派发事件前先把快照写回，保证 OnClick 里读到的是用户刚输的内容。
  事件目标控件（ASkipId）跳过：它自己的值由 LWApplyValue 按 val 处理 }
procedure LWApplyFieldSnapshot(S: TLWSession; AVals: TJSONObject; ASkipId: Integer);
var
  i, cid: Integer;
  c: TComponent;
  tmp: TJSONObject;
begin
  if AVals = nil then Exit;
  for i := 0 to AVals.Count - 1 do
  begin
    cid := StrToIntDef(AVals.Names[i], 0);
    if (cid = 0) or (cid = ASkipId) then Continue;
    c := S.CompById(cid);
    if (c = nil) or (not LWIsSnapField(c)) then Continue;
    tmp := TJSONObject.Create;
    try
      tmp.Add('val', AVals.Items[i].AsString);
      LWApplyValue(c, tmp);
    finally
      tmp.Free;
    end;
  end;
end;

{ TSplitter 拖动：把客户端的相对位移 sd 直接应用到同侧邻居的尺寸上。
  坑 188（2026-11-19 用户实测「第一次能移到一定位置，之后再拖就不动了」）：
  nogui / 无 widgetset 下不能走 LCL 的 SetSplitterPosition：
    1) MoveSplitter 只改邻居 Width/Height，Splitter 自己的 Left/Top 停在
       设计期值（Panel2 已被拖到 273，Splitter.Left 仍是 260）；
    2) 下一次拖动的 FindAlignControl 要求「邻居右边界 <= Splitter.Left」，
       第一次把邻居拖宽后条件就不成立，永远返回 nil —— 只能拖一次；
    3) 手动改 Splitter.Left 去"修"会更糟：FindAlignOtherControl 靠
       Splitter.BoundsRect 找 alClient 邻居，位置一动就找不到，EndSize
       退化成负数，邻居被夹到 1px。
  所以这里完全绕开 LCL 的坐标状态机：按 Align 找同侧邻居（alLeft 取右边界
  最大的那个，即紧贴分隔条左侧的控件），直接给它的 Width/Height 加 sd。
  客户端 runLayout 本来就只按 align + w 重排，服务端坐标不需要自洽。 }
procedure LWMoveSplitter(sp: TSplitter; ASd: Integer);
var
  p: TWinControl;
  i, v, bestV, newSize: Integer;
  ctl, target: TControl;
  horiz, grow: Boolean;
begin
  if (sp = nil) or (ASd = 0) then Exit;
  p := sp.Parent;
  if p = nil then Exit;
  horiz := sp.Align in [alLeft, alRight];
  { 同侧邻居：紧贴分隔条、位于其"被调整侧"的那个控件 }
  target := nil;
  bestV := Low(Integer);
  for i := 0 to p.ControlCount - 1 do
  begin
    ctl := p.Controls[i];
    if (ctl = sp) or (not ctl.Visible) then Continue;
    if ctl.Align <> sp.Align then Continue;
    case sp.Align of
      alLeft:   v := ctl.Left + ctl.Width;
      alRight:  v := -ctl.Left;
      alTop:    v := ctl.Top + ctl.Height;
      alBottom: v := -ctl.Top;
    else
      v := Low(Integer);
    end;
    if (target = nil) or (v > bestV) then
    begin
      target := ctl;
      bestV := v;
    end;
  end;
  { 没有同侧邻居（只有 alClient）：退回 LCL 原生语义，能调多少算多少 }
  if target = nil then
  begin
    sp.SetSplitterPosition(sp.GetSplitterPosition + ASd);
    Exit;
  end;

  { alLeft/alTop：往右/下拖增大邻居；alRight/alBottom：方向相反 }
  grow := sp.Align in [alLeft, alTop];
  if horiz then
  begin
    if grow then newSize := target.Width + ASd
    else newSize := target.Width - ASd;
    if newSize < 8 then newSize := 8;
    target.Width := newSize;
  end
  else
  begin
    if grow then newSize := target.Height + ASd
    else newSize := target.Height - ASd;
    if newSize < 8 then newSize := 8;
    target.Height := newSize;
  end;
end;

function LWHandleEvent(S: TLWSession; AReq: TJSONObject; out AErr: string): TJSONObject;
var
  c: TComponent;
  ev: string;
  id: Integer;
  mf: TCustomForm;
  f: TCustomForm;
  ownerF: TComponent;
  pg: Integer;
begin
  AErr := '';
  Result := nil;
  id := JGetInt(AReq, 'id', 0);
  ev := JGetStr(AReq, 'ev');
  { 增量补丁：客户端带回它已应用的树版本（tver）+ 是否支持补丁（patch=1）。
    没带（老缓存 / Ext 渲染层）就一律发全量 —— 这样开着 --patch=1 也不会
    把老前端打死。判定放进会话，两条事件路径（HTTP / WS）自动都生效 }
  S.BeginEventPatch(JGetInt(AReq, 'tver', -1), not JGetBool(AReq, 'patch', False));
  c := S.CompById(id);
  if c = nil then
  begin
    AErr := 'component not found: ' + IntToStr(id);
    Exit;
  end;

  { 登录拦截：启用了登录（RequireAuth）且尚未认证的会话，只允许操作
    登录窗体上的控件；其余事件一律拒绝（防止未登录者触发业务逻辑）。
    判定方法：沿 Owner 找到控件所在窗体，必须是 TLWLoginForm 及其子类 }
  if S.RequireAuth and (not S.Authenticated) then
  begin
    ownerF := c;
    while (ownerF <> nil) and not (ownerF is TCustomForm) do
      ownerF := ownerF.Owner;
    if not (ownerF is TLWLoginForm) then
    begin
      AErr := 'not authenticated';
      Exit;
    end;
  end;

  LWCurrentSession := S;
  try
    { 先把同一窗体里其他输入控件的最新值写回（见 LWApplyFieldSnapshot） }
    LWApplyFieldSnapshot(S, JGetObj(AReq, 'vals'), id);
    LWApplyValue(c, AReq);
    LWApplyGridPos(c, AReq);
    { 分页/过滤是框架级事件（不是业务事件签名），直接改写运行时状态，
      下一轮序列化自然带出新的一页/过滤结果 }
    if (c is TLWDBGrid) and (ev = 'OnPageChange') then
    begin
      pg := StrToIntDef(JGetStr(AReq, 'val'), TLWDBGrid(c).CurrentPage);
      if pg >= 1 then TLWDBGrid(c).CurrentPage := pg;
    end
    else if (c is TLWDBGrid) and (ev = 'OnFilter') then
    begin
      TLWDBGrid(c).FilterText := Trim(JGetStr(AReq, 'val'));
      TLWDBGrid(c).CurrentPage := 1;
    end
    { TDBNavigator 的 OnClick 是两参事件，且 BtnClick 内部自己会触发它，
      必须在通用事件调用之前截获，否则 TNotifyEvent 强转签名会栈错乱 }
    else if (c is TDBNavigator) and (ev = 'OnClick') then
      LWApplyDBNavClick(c, AReq)
    else if (c is TDBGrid) and (ev = 'OnSetFieldValue') then
      LWApplyDBGridEdit(c, AReq)
    else if (c is TCheckGroup) and (ev = 'OnItemClick') then
      LWApplyCheckGroupClick(c, AReq)
    else if (c is TValueListEditor) and (ev = 'OnValidate') then
      LWApplyVLEValidate(c, AReq)
    { TSplitter 拖动：客户端拖完回传位移增量 sd（像素，可正可负）。
      走 LWMoveSplitter（见坑 188）：SetSplitterPosition 只改邻居尺寸，
      nogui 下不改 Splitter 自身坐标，必须补一次位置同步，否则第二次拖动
      FindAlignControl 找不到目标。框架级事件（非业务签名），不进 LWInvokeEvent。 }
    else if (c is TSplitter) and (ev = 'OnSplitterMove') then
      LWMoveSplitter(TSplitter(c), JGetInt(AReq, 'sd', 0))
    else
      LWInvokeEvent(c, ev, JGetInt(AReq, 'row', -1), JGetInt(AReq, 'col', -1));

    { 模态窗体：业务代码只写 ModalResult := mrOk 也要能自动关闭 }
    mf := S.ModalForm;
    if mf <> nil then
      S.SessionNotify(Format('ev %s on %s -> modal %s ModalResult=%d',
        [ev, c.Name, mf.Name, Ord(mf.ModalResult)]));
    if (mf <> nil) and (mf.ModalResult <> mrNone) then
      S.SessionEndModal(mf, mf.ModalResult);

    { 点窗口右上角关闭：等同于取消 }
    if (ev = 'OnClose') and (c is TCustomForm) then
    begin
      f := TCustomForm(c);
      if (S.ModalForm = f) then
        S.SessionEndModal(f, mrCancel);
    end;
  finally
    LWCurrentSession := nil;
  end;

  Result := S.BuildEventPayload;
end;

end.
