open Prim

type atom =
  | Var of Id.t
  | Root of Id.t

type closure = { entry : Id.l * Type.t; actual_fv : atom list }

type t =
  | Unit
  | Bool of bool
  | Int of int
  | Float of float
  | Prim of primitive * atom list
  | If of atom * t * t
  | Let of (atom * Type.t) * t * t
  | Atom of atom
  | MakeCls of closure
  | AppCls of atom * atom list
  | AppDir of Id.l * atom list
  | LetTuple of (atom * Type.t) list * atom * t
  | ExtArray of Id.l * Type.t
  | ExtFunApp of Id.l * Type.t * atom list

let rec triggers = function
  | Closure.Unit | Closure.Bool(_) | Closure.Int(_)
  | Closure.Float(_) -> false
  | Closure.Prim (Pmakearray, _)
  | Closure.Prim (Pmaketuple, _) -> true
  | Closure.Prim _ -> false
  | Closure.If (_, e1, e2)
  | Closure.Let (_, e1, e2) -> triggers e1 || triggers e2
  | Closure.Var _ -> false
  | Closure.MakeCls _ -> true
  | Closure.AppCls _ | Closure.AppDir _ -> false
  | Closure.LetTuple (_, _, e) -> triggers e
  | Closure.ExtArray _ -> false
  | Closure.ExtFunApp _ -> false
    (* is this right? could an external function allocate memory!? *)

let remove_list l s =
  List.fold_right S.remove l s

let rec roots e =
  match e with
  | Closure.Unit | Closure.Bool _ | Closure.Int _
  | Closure.Float _ -> S.empty
  | Closure.Prim (Pmakearray, xs)
  | Closure.Prim (Pmaketuple, xs) -> S.of_list xs
  | Closure.Prim _ -> S.empty
  | Closure.If (_, e1, e2) ->
      S.union (roots e1) (roots e2)
  | Closure.Let ((id, _), e1, e2) when triggers e1 ->
      S.remove id (S.union (roots e1) (Closure.fv e2))
  | Closure.Let ((id, _), _, e2) ->
      S.remove id (roots e2)
  | Closure.Var _ -> S.empty
  | Closure.MakeCls (clos) ->
      S.of_list clos.Closure.actual_fv
  | Closure.AppCls _ | Closure.AppDir _ -> S.empty
  | Closure.LetTuple (idtl, _, e) ->
      remove_list (List.map (fun (id, _) -> id) idtl) (roots e)
  | Closure.ExtArray _ | Closure.ExtFunApp _ -> S.empty

let is_gc_type = function
  | Type.Fun _ | Type.Tuple _ | Type.Array _ -> true
  | _ -> false

let add x t env r =
  if S.mem x r && is_gc_type t then
    (Printf.eprintf "%s " x;
    (Root x, M.add x true env))
  else
    (Var x, M.add x false env)

let g_atom env id =
  let is_root = M.find id env in
  if is_root then Root id
  else Var id

let rec g env = function
  | Closure.Unit -> Unit
  | Closure.Bool(b) -> Bool(b)
  | Closure.Int(n) -> Int(n)
  | Closure.Float(f) -> Float(f)
  | Closure.Prim (p, xs) -> Prim (p, List.map (g_atom env) xs)
  | Closure.If (x, e1, e2) ->
      If (Var x, g env e1, g env e2)
  | Closure.Let ((x, t), e1, e2) ->
      let v, env' = add x t env (roots e2) in
      Let ((v, t), g env e1, g env' e2)
  | Closure.Var (x) ->
      Atom (g_atom env x)
  | Closure.MakeCls (clos) ->
      MakeCls ({ entry = clos.Closure.entry; actual_fv =
        List.map (g_atom env) clos.Closure.actual_fv })
  | Closure.AppCls (x, idl) ->
      AppCls (g_atom env x, List.map (g_atom env) idl)
  | Closure.AppDir (x, idl) ->
      AppDir (x, List.map (g_atom env) idl)
  | Closure.LetTuple (idtl, x, e) ->
      let x = g_atom env x in
      let r = roots e in
      let rec loop env yl = function
        | [] ->
            LetTuple (List.rev yl, x, g env e)
        | (id, t) :: rest ->
            let v, env' = add id t env r in
            loop env' ((v, t) :: yl) rest
      in loop env [] idtl
  | Closure.ExtArray (x, t) ->
      ExtArray (x, t)
  | Closure.ExtFunApp (x, t, idl) ->
      ExtFunApp (x, t, List.map (g_atom env) idl)

type fundef = { name : Id.l * Type.t;
  args : (atom * Type.t) list;
  formal_fv : (atom * Type.t) list;
  body : t }

type prog = Prog of fundef list * t

let f_fundef fundef =
  let r = roots fundef.Closure.body in
  (* (let Id.L name, _ = fundef.Closure.name in
    Printf.eprintf "roots for %s: %s\n" name
      (String.concat " " (S.elements r))); *)
  let rec loop env yl = function
    | [] ->
        List.rev yl, env
    | (x, t) :: rest ->
        let v, env = add x t env r in
        loop env ((v, t) :: yl) rest in
  let Id.L name, _ = fundef.Closure.name in
  Printf.eprintf "Roots for %s: " name;
  let args, env = loop M.empty [] fundef.Closure.args in
  let formal_fv, env = loop env [] fundef.Closure.formal_fv in
  let body = g env fundef.Closure.body in
  Printf.eprintf "\n";
  { name = fundef.Closure.name;
    args = args; formal_fv = formal_fv;
    body = body }

let f (Closure.Prog(fundefs, e)) =
  Prog (List.map f_fundef fundefs, g M.empty e)
