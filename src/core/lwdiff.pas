{
  lazarusWeb :: lwdiff
  ------------------------------------------------------------------
  增量补丁（阶段 2）：比较两次 BuildPayload 的 forms 数组，产出 ops。

  为什么只省"编码 + 传输"，不省"序列化"：
    BuildPayloadCore 每次仍要把 157 个控件的属性读一遍（4~5ms），这一步
    在阶段 3（序列化缓存）才会动。这里省掉的是
      - 全量树的 JSON 编码（1.16ms → ~0.05ms）
      - 每次 78KB 的载荷（→ 1~3KB）
    对远程/手机用户价值最大：一次点击从 0.6Mbps 降到 ~20kbps。

  协议（客户端 lw-alpine.js 的 applyPatch 对应实现）：
    请求带 sid/id/ev/tver(=已应用的树版本)/patch(=1 声明前端懂补丁)
    响应 ok/tver/base/patch，patch 是数组，元素为 "f"(窗体 id) + "ops"
    ops 用数组而不是对象，一个事件里 ops 是两位数以内，每条省 30 字节：
      ["p", id, props]        按 id 改属性（只含变化的键；消失的键给 null）
      ["a", 父id, 下标, node]  插入新节点（带整棵子树）
      ["d", id]               删除整棵子树
      ["m", id, 父id, 下标]    同父下移动位置

  回退（调用方根据 AStats 判断，见 lwsession.BuildEventPayload）：
    - 窗体集合变化（ShowModal / Show / Free）→ 本函数返回 nil，发全量；
    - 增删节点过多 → 发全量（全量反而更小、更可靠）。

  性能（这是本单元最容易被忽略的部分）：
    差异算法本身是 O(节点数)，但"按 id 找节点"的数据结构选错会把常数
    放大三个数量级。初版用 TStringList（Sorted 查找 → AnsiCompareStr，
    Windows 上是带 locale 的 CompareStringW，~10µs/次）+ fpjson 的
    TJSONObject.Find（线性 + 大小写不敏感），160 个节点要 20~26ms，
    比它省下的 JSON 编码（1.2ms）贵二十倍 —— 补丁反而比全量慢 4 倍。
    现在全部换成整型开放寻址哈希 + 位置索引：纯位运算，任何平台同一份
    代码、同样的常数，不碰 locale、不做字符串分配。
}
unit lwdiff;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

type
  TLWDiffStats = record
    Added: Integer;     { 新增节点数（含子树，只算 op 覆盖的根） }
    Removed: Integer;
    Changed: Integer;   { 属性变化的节点数 }
    Moved: Integer;
    Nodes: Integer;     { 新树的节点总数，供调用方算比例 }
  end;

{ 比较两份 forms 数组，返回按窗体分组的 ops 数组。
  AOld 为 nil（还没有基线）、或窗体集合不一致时返回 nil —— 必须发全量。 }
function LWDiffForms(AOld, ANew: TJSONArray; out AStats: TLWDiffStats): TJSONArray;

implementation

type
  { id -> 节点 / 父节点 / 在父 children 里的下标。都不拥有对象。
    开放寻址（线性探测），槽位数永远是 2 的幂，负载因子 <= 3/4。
    FOrder 记插入顺序（= 前序遍历），遍历用它 —— 哈希槽的顺序没有语义。 }
  TNodeIndex = class
  private
    FKeys: array of Integer;        { -1 = 空槽；节点 id 恒 >= 0 }
    FNodes: array of TJSONObject;
    FParents: array of TJSONObject;
    FPos: array of Integer;
    FOrder: array of Integer;
    FCount: Integer;
    FMask: Integer;
    procedure Rehash(ANewCap: Integer);
    function Probe(AId: Integer): Integer;   { 命中返回所在槽，未命中返回空槽 }
  public
    constructor Create;
    procedure Add(AId: Integer; ANode, AParent: TJSONObject; APos: Integer);
    function Has(AId: Integer): Boolean;
    function NodeOf(AId: Integer): TJSONObject;
    function ParentOf(AId: Integer): TJSONObject;
    function PosOf(AId: Integer): Integer;
    function KeyAt(AIndex: Integer): Integer;
    property Count: Integer read FCount;
  end;

  { 子节点顺序模拟用的小整数表。TStringList 在这里同样会掉进 locale
    比较的坑（Index/Delete/Insert 都是线性比较），而它每个事件要跑好几遍 }
  TIntList = class
  private
    FItems: array of Integer;
    FCount: Integer;
    function GetItem(AIndex: Integer): Integer;
  public
    procedure Clear;
    procedure Add(AId: Integer);
    procedure Insert(AIndex, AId: Integer);
    procedure Delete(AIndex: Integer);
    function IndexOf(AId: Integer): Integer;
    property Count: Integer read FCount;
    property Items[AIndex: Integer]: Integer read GetItem; default;
  end;

constructor TNodeIndex.Create;
begin
  inherited Create;
  FCount := 0;
  FOrder := nil;
  Rehash(64);
end;

procedure TNodeIndex.Rehash(ANewCap: Integer);
var
  i, slot, oldCap: Integer;
  oldKeys, oldPos: array of Integer;
  oldNodes, oldParents: array of TJSONObject;
begin
  oldCap := Length(FKeys);
  oldKeys := FKeys;
  oldNodes := FNodes;
  oldParents := FParents;
  oldPos := FPos;

  SetLength(FKeys, ANewCap);
  SetLength(FNodes, ANewCap);
  SetLength(FParents, ANewCap);
  SetLength(FPos, ANewCap);
  for i := 0 to ANewCap - 1 do
  begin
    FKeys[i] := -1;
    FNodes[i] := nil;
    FParents[i] := nil;
  end;
  FMask := ANewCap - 1;

  for i := 0 to oldCap - 1 do
    if oldKeys[i] >= 0 then
    begin
      slot := Probe(oldKeys[i]);
      FKeys[slot] := oldKeys[i];
      FNodes[slot] := oldNodes[i];
      FParents[slot] := oldParents[i];
      FPos[slot] := oldPos[i];
    end;
end;

function TNodeIndex.Probe(AId: Integer): Integer;
var
  h: Cardinal;
begin
  { Knuth 乘法散列 + 一次高低位混合。id 是连号的小整数，直接用低位会
    撞成一串；这一步保证同一次 BuildPayload 的 id 均匀铺开 }
  h := Cardinal(AId) * Cardinal($9E3779B1);
  h := h xor (h shr 16);
  Result := Integer(h and Cardinal(FMask));
  while FKeys[Result] >= 0 do
  begin
    if FKeys[Result] = AId then Exit;
    Result := (Result + 1) and FMask;
  end;
end;

procedure TNodeIndex.Add(AId: Integer; ANode, AParent: TJSONObject; APos: Integer);
var
  slot: Integer;
begin
  if (FCount + 1) * 4 > Length(FKeys) * 3 then
    Rehash(Length(FKeys) * 2);
  slot := Probe(AId);
  if FKeys[slot] = AId then
  begin
    { 重复 id（writer 不该产出）：后者覆盖，槽位与顺序都不动 }
    FNodes[slot] := ANode;
    FParents[slot] := AParent;
    FPos[slot] := APos;
    Exit;
  end;
  FKeys[slot] := AId;
  FNodes[slot] := ANode;
  FParents[slot] := AParent;
  FPos[slot] := APos;
  if FCount = Length(FOrder) then
    SetLength(FOrder, FCount * 2 + 8);
  FOrder[FCount] := AId;
  Inc(FCount);
end;

function TNodeIndex.Has(AId: Integer): Boolean;
var
  slot: Integer;
begin
  slot := Probe(AId);
  Result := FKeys[slot] = AId;
end;

function TNodeIndex.NodeOf(AId: Integer): TJSONObject;
var
  slot: Integer;
begin
  slot := Probe(AId);
  if FKeys[slot] = AId then
    Result := FNodes[slot]
  else
    Result := nil;
end;

function TNodeIndex.ParentOf(AId: Integer): TJSONObject;
var
  slot: Integer;
begin
  slot := Probe(AId);
  if FKeys[slot] = AId then
    Result := FParents[slot]
  else
    Result := nil;
end;

function TNodeIndex.PosOf(AId: Integer): Integer;
var
  slot: Integer;
begin
  slot := Probe(AId);
  if FKeys[slot] = AId then
    Result := FPos[slot]
  else
    Result := 0;
end;

function TNodeIndex.KeyAt(AIndex: Integer): Integer;
begin
  if (AIndex >= 0) and (AIndex < FCount) then
    Result := FOrder[AIndex]
  else
    Result := -1;
end;

{ ---- TIntList ---- }

function TIntList.GetItem(AIndex: Integer): Integer;
begin
  Result := FItems[AIndex];
end;

procedure TIntList.Clear;
begin
  FCount := 0;
end;

procedure TIntList.Add(AId: Integer);
begin
  if FCount = Length(FItems) then
    SetLength(FItems, FCount * 2 + 8);
  FItems[FCount] := AId;
  Inc(FCount);
end;

procedure TIntList.Insert(AIndex, AId: Integer);
begin
  if FCount = Length(FItems) then
    SetLength(FItems, FCount * 2 + 8);
  if AIndex < FCount then
    Move(FItems[AIndex], FItems[AIndex + 1], (FCount - AIndex) * SizeOf(Integer));
  FItems[AIndex] := AId;
  Inc(FCount);
end;

procedure TIntList.Delete(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FCount) then Exit;
  if AIndex < FCount - 1 then
    Move(FItems[AIndex + 1], FItems[AIndex], (FCount - AIndex - 1) * SizeOf(Integer));
  Dec(FCount);
end;

function TIntList.IndexOf(AId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do
    if FItems[i] = AId then Exit(i);
  Result := -1;
end;

{ ---- 树遍历 ---- }

function NodeId(N: TJSONObject): Integer;
var
  d: TJSONData;
begin
  Result := 0;
  if N = nil then Exit;
  d := N.Find('id');
  if d <> nil then
    Result := d.AsInteger;
end;

{ children 永远是 writer 最后写的几个键之一，从后往前扫一次就命中。
  不能小看这一点：fpjson 的 Find 是**线性 + 大小写不敏感**的扫描
  （Windows 上每次比较都是带 locale 的 CompareStringW），160 个节点
  各扫 25 个属性就是十几毫秒 —— 白白吃掉补丁省下的编码时间。 }
function ChildrenOf(N: TJSONObject): TJSONArray;
var
  i: Integer;
  d: TJSONData;
begin
  Result := nil;
  if N = nil then Exit;
  for i := N.Count - 1 downto 0 do
    if N.Names[i] = 'children' then
    begin
      d := N.Items[i];
      if (d <> nil) and (d.JSONType = jtArray) then
        Result := TJSONArray(d);
      Exit;
    end;
end;

procedure IndexTree(N: TJSONObject; AParent: TJSONObject; APos: Integer;
  IX: TNodeIndex);
var
  a: TJSONArray;
  i: Integer;
begin
  IX.Add(NodeId(N), N, AParent, APos);
  a := ChildrenOf(N);
  if a = nil then Exit;
  for i := 0 to a.Count - 1 do
    if (a.Items[i] <> nil) and (a.Items[i].JSONType = jtObject) then
      IndexTree(TJSONObject(a.Items[i]), N, i, IX);
end;

{ 深比较。属性名集合由 writer 决定，两边同源，所以"数量相同 + 逐个按位取"
  就够了；数值统一走 AsFloat（1 与 1.0 语义相同） }
function JSONSame(A, B: TJSONData): Boolean;
var
  i: Integer;
  oa, ob: TJSONObject;
  aa, ab: TJSONArray;
begin
  if A = B then Exit(True);
  if (A = nil) or (B = nil) then Exit(False);
  if A.JSONType <> B.JSONType then
  begin
    if (A.JSONType = jtNumber) and (B.JSONType = jtNumber) then
      Exit(A.AsFloat = B.AsFloat);
    Exit(False);
  end;
  case A.JSONType of
    jtNull: Result := True;
    jtBoolean: Result := A.AsBoolean = B.AsBoolean;
    jtNumber: Result := A.AsFloat = B.AsFloat;
    jtString: Result := A.AsString = B.AsString;
    jtArray:
      begin
        aa := TJSONArray(A);
        ab := TJSONArray(B);
        if aa.Count <> ab.Count then Exit(False);
        for i := 0 to aa.Count - 1 do
          if not JSONSame(aa.Items[i], ab.Items[i]) then Exit(False);
        Result := True;
      end;
    jtObject:
      begin
        oa := TJSONObject(A);
        ob := TJSONObject(B);
        if oa.Count <> ob.Count then Exit(False);
        { 两份 JSON 由同一个 writer 产出，键的顺序一致 —— 按位置比，
          只有顺序对不上时才回退到按名查（Find 很贵，见 ChildrenOf 注释）}
        for i := 0 to oa.Count - 1 do
          if (i < ob.Count) and (oa.Names[i] = ob.Names[i]) then
          begin
            if not JSONSame(oa.Items[i], ob.Items[i]) then Exit(False);
          end
          else if not JSONSame(oa.Items[i], ob.Find(oa.Names[i])) then
            Exit(False);
        Result := True;
      end;
  else
    Result := A.AsJSON = B.AsJSON;
  end;
end;

{ 变化的属性集合（不含 children）。没有变化返回 nil。
  老有新无的键写 null —— 客户端合并时把旧值清掉。
  典型场景：TImage 清空图片后 writer 不再下发 src。 }
function DiffProps(AOld, ANew: TJSONObject; out AChanged: Integer): TJSONObject;
var
  i: Integer;
  nm: string;
  nv, ov: TJSONData;
  sameNames: Boolean;
begin
  Result := nil;
  AChanged := 0;
  for i := 0 to ANew.Count - 1 do
  begin
    nm := ANew.Names[i];
    if nm = 'children' then Continue;
    nv := ANew.Items[i];
    { 同一个 writer 产的节点键序一致，按位置取；顺序不同才按名查 }
    if (i < AOld.Count) and (AOld.Names[i] = nm) then
      ov := AOld.Items[i]
    else
      ov := AOld.Find(nm);
    if (ov = nil) or (not JSONSame(ov, nv)) then
    begin
      if Result = nil then Result := TJSONObject.Create;
      Result.Add(nm, nv.Clone);
      Inc(AChanged);
    end;
  end;
  { 有没有"老有新无"的键。这里不能只看 Count：增一个键 + 删一个键时数量
    相同，但消失的那个键必须给 null 才能让客户端把它清掉（对拍里真出过：
    老树删了 w、加了 rows，客户端上 w 就一直留在 DOM 上）。
    键名序列逐位比是二进制比较，比逐个 Find 便宜得多 }
  sameNames := (AOld.Count = ANew.Count);
  if sameNames then
    for i := 0 to AOld.Count - 1 do
      if AOld.Names[i] <> ANew.Names[i] then
      begin
        sameNames := False;
        Break;
      end;
  if not sameNames then
    for i := 0 to AOld.Count - 1 do
    begin
      nm := AOld.Names[i];
      if nm = 'children' then Continue;
      if ANew.Find(nm) = nil then
      begin
        if Result = nil then Result := TJSONObject.Create;
        Result.Add(nm, TJSONNull.Create);
        Inc(AChanged);
      end;
    end;
end;

{ 一个父节点的 children 顺序是否需要调整。
  ACur 是"客户端此刻的列表"（按服务端模拟：老顺序 + 已插入的新节点），
  ANew 是目标顺序。返回需要发的 m 操作数。
  算法和在客户端执行的一致：按下标从小到大做选择排序，只在真的错位时才发。 }
function EmitMoves(AParentId: Integer; ACur, ANew: TIntList;
  AOps: TJSONArray): Integer;
var
  i, p, id: Integer;
  op: TJSONArray;
begin
  Result := 0;
  for i := 0 to ANew.Count - 1 do
  begin
    if i >= ACur.Count then Break;
    if ACur[i] = ANew[i] then Continue;
    id := ANew[i];
    p := ACur.IndexOf(id);
    if p < 0 then Continue;          { 不可能：成员集合已对齐 }
    ACur.Delete(p);
    ACur.Insert(i, id);
    op := TJSONArray.Create;
    op.Add('m');
    op.Add(id);
    op.Add(AParentId);
    op.Add(i);
    AOps.Add(op);
    Inc(Result);
  end;
end;

{ 节点在两棵树里但换了父：LCL 里很罕见（改 Parent 才会发生），
  一律按"删 + 增"表达。跨父 move 会让同一父下的下标模拟前后错位，
  专门处理不值得 —— 一年也遇不到几次。 }
function IsCrossMoved(AOld, ANew: TNodeIndex; AId: Integer): Boolean;
begin
  Result := False;
  if (not AOld.Has(AId)) or (not ANew.Has(AId)) then Exit;
  Result := NodeId(AOld.ParentOf(AId)) <> NodeId(ANew.ParentOf(AId));
end;

{ 单个窗体：AOld / ANew 都是 form 节点 }
procedure DiffForm(AOld, ANew: TJSONObject; AOps: TJSONArray;
  var AStats: TLWDiffStats);
var
  ixo, ixn: TNodeIndex;
  i, j, id, cid, pid: Integer;
  delIds: TIntList;
  props: TJSONObject;
  chg: Integer;
  kidsOld, kidsNew: TJSONArray;
  child, par: TJSONObject;
  op: TJSONArray;
  cur, target: TIntList;
  skip: Boolean;

  procedure CollectAdds(F: TJSONObject);
  var
    ca: TJSONArray;
    k: Integer;
    cn: TJSONObject;
  begin
    ca := ChildrenOf(F);
    if ca = nil then Exit;
    for k := 0 to ca.Count - 1 do
    begin
      if (ca.Items[k] = nil) or (ca.Items[k].JSONType <> jtObject) then Continue;
      cn := TJSONObject(ca.Items[k]);
      cid := NodeId(cn);
      { 老节点且没换父：继续往下找新子节点；换了父的按"新节点"整棵带走 }
      if ixo.Has(cid) and (not IsCrossMoved(ixo, ixn, cid)) then
        CollectAdds(cn)
      else
      begin
        { 新节点：整棵子树一次带走，子孙不再单独发 }
        op := TJSONArray.Create;
        op.Add('a');
        op.Add(NodeId(F));
        op.Add(ixn.PosOf(cid));
        op.Add(cn.Clone);
        AOps.Add(op);
        Inc(AStats.Added);
      end;
    end;
  end;

begin
  ixo := TNodeIndex.Create;
  ixn := TNodeIndex.Create;
  delIds := TIntList.Create;
  cur := TIntList.Create;
  target := TIntList.Create;
  try
    IndexTree(AOld, nil, 0, ixo);
    IndexTree(ANew, nil, 0, ixn);
    Inc(AStats.Nodes, ixn.Count);   { 多窗体时累加，调用方按总数判断 }

    { ---- 1. 删：老有新无 ----
      只发"被删子树的根"：祖先已经删了的话，子孙的 d 是多余的
      （客户端 destroyNode 会整棵摘掉，但多发几十条白白让 ops 变大） }
    for i := 0 to ixo.Count - 1 do
    begin
      id := ixo.KeyAt(i);
      { 跨父移动：老位置要删（新位置由 add op 负责），不能按"还在"跳过 }
      if ixn.Has(id) then
      begin
        if IsCrossMoved(ixo, ixn, id) then
          delIds.Add(id);
        Continue;
      end;
      { 沿父链找有没有祖先也在删除集合里 }
      skip := False;
      par := ixo.ParentOf(id);
      while par <> nil do
      begin
        pid := NodeId(par);
        if not ixn.Has(pid) then
        begin
          skip := True;
          Break;
        end;
        par := ixo.ParentOf(pid);
      end;
      if skip then Continue;
      delIds.Add(id);
    end;
    for i := 0 to delIds.Count - 1 do
    begin
      op := TJSONArray.Create;
      op.Add('d');
      op.Add(delIds[i]);
      AOps.Add(op);
      Inc(AStats.Removed);
    end;

    { ---- 2. 增：新有老无 ----
      前序遍历：父节点先出现，新子树整棵带走，子孙不再单独发 }
    if ChildrenOf(ANew) <> nil then
      CollectAdds(ANew);

    { ---- 3. 改：都在，逐属性比 ----
      窗体自身的属性（标题/尺寸/状态栏）也走这条，客户端按 id 是窗体时特殊处理 }
    for i := 0 to ixn.Count - 1 do
    begin
      id := ixn.KeyAt(i);
      if not ixo.Has(id) then Continue;
      props := DiffProps(ixo.NodeOf(id), ixn.NodeOf(id), chg);
      if props = nil then Continue;
      try
        op := TJSONArray.Create;
        op.Add('p');
        op.Add(id);
        op.Add(props);          { op 拥有 props }
        props := nil;
        AOps.Add(op);
        Inc(AStats.Changed);
      finally
        props.Free;
      end;
    end;

    { ---- 4. 移：同一父下的 children 顺序 ----
      模拟客户端的列表：老顺序里剔除已删的，再按 add 的顺序**按下标插入**新节点
      （客户端就是 splice(idx, 0, node)，这里要跟着一致，否则 m 的下标会偏） }
    for i := 0 to ixn.Count - 1 do
    begin
      id := ixn.KeyAt(i);
      child := ixn.ParentOf(id);
      if child = nil then Continue;         { 窗体根：窗体顺序固定，不处理 }
      pid := NodeId(child);
      { 父节点本身是新加的：add op 已经带走了整棵子树，里面没有"移动"可言 }
      if not ixo.Has(pid) then Continue;
      if IsCrossMoved(ixo, ixn, pid) then Continue;
      kidsNew := ChildrenOf(child);
      if kidsNew = nil then Continue;
      kidsOld := ChildrenOf(ixo.NodeOf(pid));
      cur.Clear;
      target.Clear;
      if kidsOld <> nil then
        for j := 0 to kidsOld.Count - 1 do
          if (kidsOld.Items[j] <> nil) and (kidsOld.Items[j].JSONType = jtObject) then
          begin
            cid := NodeId(TJSONObject(kidsOld.Items[j]));
            if ixn.Has(cid) and (not IsCrossMoved(ixo, ixn, cid)) then
              cur.Add(cid);
          end;
      for j := 0 to kidsNew.Count - 1 do
        if (kidsNew.Items[j] <> nil) and (kidsNew.Items[j].JSONType = jtObject) then
          target.Add(NodeId(TJSONObject(kidsNew.Items[j])));
      { 新节点在客户端已经按 add 的下标插入过了，这里补上同样的插入 }
      for j := 0 to target.Count - 1 do
      begin
        cid := target[j];
        if cur.IndexOf(cid) >= 0 then Continue;
        if j > cur.Count then cur.Add(cid) else cur.Insert(j, cid);
      end;
      Inc(AStats.Moved, EmitMoves(pid, cur, target, AOps));
    end;
  finally
    ixo.Free;
    ixn.Free;
    delIds.Free;
    cur.Free;
    target.Free;
  end;
end;

function LWDiffForms(AOld, ANew: TJSONArray; out AStats: TLWDiffStats): TJSONArray;
var
  oldIds, newIds: array of Integer;
  i, j, id, cntOld, cntNew: Integer;
  fo, fn: TJSONObject;
  ops: TJSONArray;
  grp: TJSONObject;
  found: Boolean;
begin
  Result := nil;
  FillChar(AStats, SizeOf(AStats), 0);
  if (AOld = nil) or (ANew = nil) then Exit;

  { 窗体集合：只要多一个少一个就发全量 —— 窗体的增删本来就伴随
    模态切换/登录切换，那些场景本来就该整棵重来（而且量很小） }
  SetLength(oldIds, AOld.Count);
  cntOld := 0;
  for i := 0 to AOld.Count - 1 do
    if (AOld.Items[i] <> nil) and (AOld.Items[i].JSONType = jtObject) then
    begin
      oldIds[cntOld] := NodeId(TJSONObject(AOld.Items[i]));
      Inc(cntOld);
    end;
  SetLength(newIds, ANew.Count);
  cntNew := 0;
  for i := 0 to ANew.Count - 1 do
    if (ANew.Items[i] <> nil) and (ANew.Items[i].JSONType = jtObject) then
    begin
      newIds[cntNew] := NodeId(TJSONObject(ANew.Items[i]));
      Inc(cntNew);
    end;
  if cntOld <> cntNew then Exit;
  for i := 0 to cntNew - 1 do
  begin
    found := False;
    for j := 0 to cntOld - 1 do
      if oldIds[j] = newIds[i] then
      begin
        found := True;
        Break;
      end;
    if not found then Exit;
  end;

  Result := TJSONArray.Create;
  for i := 0 to ANew.Count - 1 do
  begin
    fn := TJSONObject(ANew.Items[i]);
    id := NodeId(fn);
    fo := nil;
    for j := 0 to AOld.Count - 1 do
      if (AOld.Items[j] <> nil) and (AOld.Items[j].JSONType = jtObject) and
         (NodeId(TJSONObject(AOld.Items[j])) = id) then
      begin
        fo := TJSONObject(AOld.Items[j]);
        Break;
      end;
    if fo = nil then Exit;   { 理论上不会：集合已比对过 }

    ops := TJSONArray.Create;
    grp := TJSONObject.Create;
    grp.Add('f', id);
    grp.Add('ops', ops);
    Result.Add(grp);
    DiffForm(fo, fn, ops, AStats);
  end;
end;

end.
