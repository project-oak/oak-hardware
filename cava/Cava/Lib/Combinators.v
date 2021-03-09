(****************************************************************************)
(* Copyright 2020 The Project Oak Authors                                   *)
(*                                                                          *)
(* Licensed under the Apache License, Version 2.0 (the "License")           *)
(* you may not use this file except in compliance with the License.         *)
(* You may obtain a copy of the License at                                  *)
(*                                                                          *)
(*     http://www.apache.org/licenses/LICENSE-2.0                           *)
(*                                                                          *)
(* Unless required by applicable law or agreed to in writing, software      *)
(* distributed under the License is distributed on an "AS IS" BASIS,        *)
(* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. *)
(* See the License for the specific language governing permissions and      *)
(* limitations under the License.                                           *)
(****************************************************************************)

Require Import Coq.Vectors.Vector.
Import VectorNotations.

Require Import Coq.Lists.List Coq.micromega.Lia.
Import ListNotations.

Require Import ExtLib.Structures.Monads.
Require Import ExtLib.Structures.Traversable.
Require Import coqutil.Tactics.Tactics.
Require Import Coq.Arith.PeanoNat.

Export MonadNotation.

Require Import Cava.Core.CavaClass.
Require Import Cava.Util.Identity.
Require Import Cava.Util.Vector.
Require Import Cava.Util.List.
Require Import Cava.Core.Signal.
Require Import Cava.Util.Tactics.
Require Import Cava.Lib.CavaPrelude.

Generalizable All Variables.

Require Import ExtLib.Structures.MonadLaws.

Local Open Scope monad_scope.
Local Open Scope type_scope.

Section WithCava.
  Context {signal} {semantics: Cava signal}.
  Existing Instance monad. (* make sure cava Monad instance takes precedence *)

  (****************************************************************************)
  (* Lava-style circuit combinators.                                          *)
  (****************************************************************************)

  (* Operations over the first or second element of a pair of inputs. *)

  (* pairLeft takes an input with shape (a, (b, c)) and re-organizes
      it as ((a, b), c) *)
   Definition pairLeft {A B C : SignalType}
                       (i : signal A * (signal B * signal C)) :
                       cava ((signal A * signal B) * signal C) :=
   let '(a, (b, c)) := i in
   ret ((a, b), c).

  (* pairRight takes an input with shape ((a, b), c) and re-organizes
     it as (a, (b, c)) *)
  Definition pairRight {A B C : SignalType}
                       (i : (signal A * signal B) * signal C) :
                       cava (signal A * (signal B * signal C)) :=
   let '((a, b), c) := i in
   ret (a, (b, c)).

  (* Use a circuit to zip together two vectors. *)
  Definition zipWith {A B C : SignalType} {n : nat}
           (f : signal A * signal B -> cava (signal C))
           (a : signal (Vec A n))
           (b : signal (Vec B n))
           : cava (signal (Vec C n)) :=
    a' <- unpackV a ;;
    b' <- unpackV b ;;
    v <- mapT f (vcombine a' b') ;;
    packV v.

  (* A list-based left monadic-fold. *)
  Fixpoint foldLM {m} `{Monad m} {A B : Type}
                  (f : B -> A -> m B)
                  (input : list A)
                  (accum : B)
                  : m B :=
    match input with
    | [] => ret accum
    | k::ks => st' <- f accum k  ;;
               foldLM f ks st'
    end.

  Lemma foldLM_fold_right {A B}
        (bind_ext : forall {A B} x (f g : A -> cava B),
            (forall y, f y = g y) -> bind x f = bind x g)
        (f : B -> A -> cava B) (input : list A) (accum : B) :
    foldLM f input accum =
    List.fold_right
      (fun k continuation v => bind (f v k) continuation)
      ret input accum.
  Proof.
    revert accum; induction input; intros; [ reflexivity | ].
    cbn [foldLM List.fold_right].
    eapply bind_ext; intros.
    rewrite IHinput. reflexivity.
  Qed.

  Lemma foldLM_of_ret_valid {m} `{Monad m} `{MonadLaws.MonadLaws m} {A B}
        (validA : A -> Prop) (validB : B -> Prop)
        (f : B -> A -> m B) (g : B -> A -> B) input accum :
    (forall b a, validA a -> validB b -> f b a = ret (g b a)) ->
    (forall b a, validA a -> validB b -> validB (g b a)) ->
    validB accum -> Forall validA input ->
    foldLM f input accum = ret (fold_left g input accum).
  Proof.
    intro Hfg; revert accum; induction input; intros; [ reflexivity | ].
    cbn [foldLM fold_left].
    match goal with H : Forall _ (_ :: _) |- _ => inversion H; subst; clear H end.
    rewrite Hfg, MonadLaws.bind_of_return; auto.
  Qed.


  Lemma foldLM_of_ret {m} `{Monad m} `{MonadLaws.MonadLaws m} {A B}
        (f : B -> A -> m B) (g : B -> A -> B) input accum :
    (forall b a, f b a = ret (g b a)) ->
    foldLM f input accum = ret (fold_left g input accum).
  Proof.
    intro Hfg; revert accum; induction input; intros; [ reflexivity | ].
    cbn [foldLM fold_left]. rewrite Hfg, MonadLaws.bind_of_return by auto.
    apply IHinput.
  Qed.

  Lemma foldLM_ident_fold_left
        {A B} (f : B -> A -> ident B) ls b :
    foldLM f ls b = List.fold_left f ls b.
  Proof.
    revert b; induction ls; [ reflexivity | ].
    cbn [foldLM List.fold_left]. intros.
    cbn [bind ret Monad_ident].
    rewrite IHls. reflexivity.
  Qed.

  (* Below combinator

  -----------------------------------------------------------------------------
  -- Below
  -----------------------------------------------------------------------------
  -- below r s
  --            ^
  --            |
  --            f
  --            ^
  --            |
  --          -----
  --         |     |
  --     c ->|  s  |-> e
  --         |     |
  --          -----
  --            ^
  --            |
  --            g
  --            ^
  --            |
  --          -----
  --         |     |
  --     b ->|  r  |-> d
  --         |     |
  --          -----
  --            ^
  --            |
  --            a
  -----------------------------------------------------------------------------
  *)

  Definition below {A B C D E F G}
              (r : A * B -> cava (D * G))
              (s : G * C -> cava (E * F))
              (abc : A * (B * C)) : cava ((D * E) * F) :=
    let (a, bc) := abc in
    let (b, c) := bc in
    dg <- r (a, b) ;;
    let (d, g) := dg : D * G in
    ef <- s (g, c) ;;
    let (e, f) := ef : E * F in
    ret ((d, e), f).

  (* The col combinator takes a 4-sided circuit element and replicates it by
    composing each element in a chain.

  -----------------------------------------------------------------------------
  -- 4-Sided Tile Combinators
  -----------------------------------------------------------------------------
  -- COL r
  --            a
  --            ^
  --            |
  --          -----
  --         |     |
  --     b ->|  r  |-> c
  --         |     |
  --          -----
  --            ^
  --            |
  --            a
  --            ^
  --            |
  --          -----
  --         |     |
  --     b ->|  r  |-> c
  --         |     |
  --          -----
  --            ^
  --            |
  --            a
  --            ^
  --            |
  --          -----
  --         |     |
  --     b ->|  r  |-> c
  --         |     |
  --          -----
  --            ^
  --            |
  --            a
  -----------------------------------------------------------------------------

  *)

  (* colV is a col combinator that works over Vector.t of signals.
    The input tuple is split into separate arguments so Coq can recognize
    the decreasing vector element.
  *)

  Local Open Scope vector_scope.

  Fixpoint colV' {A B C} {n : nat}
                (circuit : A * B -> cava (C * A))
                (aIn: A) (bIn: Vector.t B n) :
                cava (Vector.t C n * A) :=
    match bIn with
    | [] => ret ([], aIn)
    | x::xs => '(b0, aOut) <- circuit (aIn, x) ;;
               '(bRest, aFinal) <- colV' circuit aOut xs ;;
                ret (b0::bRest, aFinal)
    end.

  Definition colV {A B C} {n : nat}
                  (circuit : A * B -> cava (C * A))
                  (inputs: A * Vector.t B n) :
                  cava (Vector.t C n * A) :=
  colV' circuit (fst inputs) (snd inputs).

  (****************************************************************************)
  (* Make the Cava signal-level col combinator use the vector-based colV      *)
  (* under the hood.                                                          *)
  (****************************************************************************)

  Definition col {A B C} {n : nat}
               (circuit : signal A * signal B -> cava (signal C * signal A))
               (aIn: signal A) (bIn: signal (Vec B n)) :
               cava (signal (Vec C n) * signal A) :=
  b <- unpackV bIn ;;
  '(c, a) <- colV circuit (aIn, b) ;;
  cOut <- packV c ;;
  ret (cOut, a).

  Local Close Scope vector_scope.

  (* List Variant *)

  Local Open Scope list_scope.

  Fixpoint colL' {m} `{Monad m} {A B C}
                (circuit : A * B -> m (C * A))
                (aIn: A) (bIn: list B) :
                m (list C * A) :=
    match bIn with
    | [] => ret ([], aIn)
    | x::xs => '(b0, aOut) <- circuit (aIn, x) ;;
              '(bRest, aFinal) <- colL' circuit aOut xs ;;
                ret (b0::bRest, aFinal)
    end.

  Definition colL {m} `{Monad m} {A B C}
                  (circuit : A * B -> m (C * A))
                  (inputs: A * list B) :
                  m (list C * A) :=
  colL' circuit (fst inputs) (snd inputs).

  Local Close Scope vector_scope.

  (****************************************************************************)
  (* Forks in wires                                                           *)
  (****************************************************************************)

  Definition fork2 {A} (a:A) := ret (a, a).

  (****************************************************************************)
  (* Operations over pairs.                                                   *)
  (****************************************************************************)

  Definition first {A B C} (f : A -> cava C) (ab : A * B) : cava (C * B) :=
    let '(a, b) := ab in
    c <- f a ;;
    ret (c, b).

  Definition second {A B C} (f : B -> cava C) (ab : A * B) : cava (A * C) :=
    let '(a, b) := ab in
    c <- f b ;;
    ret (a, c).

  (* Project out the first element of a pair. *)
  Definition projFst {A B} (ab : A * B) : cava A :=
    let '(a, _) := ab in
    ret a.

  (* Project out the second element of a pair. *)
  Definition projSnd {A B} (ab : A * B) : cava B :=
    let '(_, b) := ab in
    ret b.

  (****************************************************************************)
  (* Swap                                                                     *)
  (****************************************************************************)

  Definition swap {A B}
                  (i : signal A * signal B) 
                  : cava (signal B * signal A) :=
    let (a, b) := i in
    ret (b, a).

  (****************************************************************************)
  (* Split a bus into two halves.                                             *)
  (****************************************************************************)

  Definition halve {A} (l : list A) : list A * list A :=
    let mid := (length l) / 2 in
    (firstn mid l, skipn mid l).

  (****************************************************************************)
  (* A binary tree combinator, list version.                                                *)
  (****************************************************************************)

  Fixpoint treeList {T: Type} {m} `{Monad m}
                    (circuit: T -> T -> m T) (def: T)
                    (n : nat) (v: list T) : m T :=
    match n with
    | O => match v return m T with
          | [a; b]=> circuit a b
          | _ => ret def
          end
    | S n' => let '(vL, vH) := halve v in
            aS <- treeList circuit def n' vL ;;
            bS <- treeList circuit def n' vH ;;
            circuit aS bS
    end.

  Definition treeWithList {T: Type} {m} `{Monad m}
                          (circuit: T -> T -> m T) (def: T)
                          (n : nat) (v: Vector.t T (2^(n+1))) : m T :=
    treeList circuit def n (to_list v).

  Lemma treeList_equiv
        {T} {cava} {monad' : Monad cava}
        {monad_laws : MonadLaws monad'}
        (id : T)
        (op : T -> T -> T)
        (op_id_left : forall a : T, op id a = a)
        (op_id_right : forall a : T, op a id = a)
        (op_assoc :
          forall a b c : T,
            op a (op b c) = op (op a b) c)
        (circuit : T -> T -> cava T)
        (circuit_equiv :
          forall a b : T, circuit a b = ret (op a b))
        (def : T) (n : nat) :
    forall v,
      length v = 2 ^ (S n) ->
      treeList circuit def n v = ret (List.fold_left op v id).
  Proof.
    induction n; intros; [ | ].
    { (* n = 0 *)
      change (2 ^ 1) with 2 in *.
      destruct_lists_by_length. cbn [treeList fold_left].
      rewrite op_id_left, circuit_equiv.
      reflexivity. }
    { (* n = S n' *)
      cbn [treeList halve]. rewrite !Nat.pow_succ_r in * by lia.
      erewrite <-Nat.div_unique_exact by eauto.
      rewrite !IHn by (rewrite ?firstn_length, ?skipn_length; lia).
      rewrite !bind_of_return, circuit_equiv by typeclasses eauto.
      rewrite <-fold_left_assoc, <-fold_left_app by eauto.
      rewrite firstn_skipn. reflexivity. }
  Qed.

  (****************************************************************************)
  (* A binary tree combinator, Vector version.                                                  *)
  (****************************************************************************)

  Definition divide {A n} (default : A) (v : Vector.t A (2 ^ (S n))) :
    Vector.t A (2 ^ n) * Vector.t A (2 ^ n) :=
    splitat _ (@resize_default A (2 ^ (S n)) default (2 ^ n + 2 ^ n) v).

  Fixpoint pow2tree_generic {T: Type} {m} `{Monad m}
                         (default : T) (n : nat)
                         (circuit: T -> T -> m T)
                         : Vector.t T (2^n) -> m T :=
    match n as n return Vector.t T (2^n) -> m T with
    | O => fun v : Vector.t T 1 => ret (Vector.hd v)
    | S n'=>
      fun vR =>
        let '(vL, vH) := divide default vR in
        aS <- pow2tree_generic default n' circuit vL ;;
        bS <- pow2tree_generic default n' circuit vH ;;
        circuit aS bS
    end.

  Lemma append_divide {A} d n H (v : t A (2 ^ (S n))) :
    (fst (divide d v) ++ snd (divide d v))%vector = resize _ H v.
  Proof.
    cbv [divide].
    let H := fresh in
    match goal with
    | |- context [splitat ?n ?v] =>
      pose proof (surjective_pairing (splitat n v)) as H
    end;
      apply append_splitat in H;
      rewrite <-H; clear H.
    rewrite resize_default_eq with (d0:=d).
    reflexivity.
  Qed.

  (* A specialization of pow2tree_generic that is constrained to take Cava
    signal types i.e. only types that we support as values over wires for Cava
    circuits. This allows the default value to be computed automatically. *)
  Definition pow2tree {t: SignalType} n
                   (circuit: signal t * signal t -> cava (signal t))
                   (v : signal (Vec t (2^n))) :
                   cava (signal t) :=
    v <- unpackV v ;;
    pow2tree_generic defaultSignal n (fun a b => circuit (a, b)) v.

  Local Open Scope nat_scope.

  Lemma pow2tree_generic_equiv'
        {T}  {monad_laws : MonadLaws monad} (valid : T -> Prop)
        (id : T)
        (op : T -> T -> T)
        (valid_id : valid id)
        (op_preserves_valid : forall a b, valid a -> valid b -> valid (op a b))
        (op_id_left : forall a : T, valid a -> op id a = a)
        (op_id_right : forall a : T, valid a -> op a id = a)
        (op_assoc :
           forall a b c : T,
             valid a -> valid b -> valid c ->
             op a (op b c) = op (op a b) c)
        (circuit : T -> T -> cava T)
        (circuit_equiv :
          forall a b : T, valid a -> valid b -> circuit a b = ret (op a b))
        (default : T) (n : nat) :
    forall v,
      ForallV valid v ->
      pow2tree_generic default n circuit v = ret (Vector.fold_left op id v).
  Proof.
    induction n; intros.
    { change (2 ^ 0) with 1 in *.
      cbn [pow2tree_generic ForallV] in *.
      autorewrite with push_vector_fold vsimpl.
      rewrite op_id_left by tauto. reflexivity. }
    { cbn [pow2tree_generic]. destruct_pair_let.
      assert (2 ^ (S n) = 2 ^ n + 2 ^ n) as Heq
        by abstract (rewrite Nat.pow_succ_r by lia; lia).
      lazymatch goal with
      | _ : ForallV ?P ?v |- context [divide ?d ?v] =>
        let H' := fresh in
        assert (ForallV P (fst (divide d v) ++ snd (divide d v))%vector) as H'
            by (rewrite @append_divide with (H:=Heq);
                apply ForallV_resize; auto);
          apply ForallV_append in H'; destruct H'
      end.
      rewrite !IHn by eauto.
      rewrite !bind_of_return by eauto.
      rewrite circuit_equiv by (apply fold_left_preserves_valid; solve [eauto]).
      erewrite <-fold_left_S_assoc' with (valid0:=valid); auto;
        [ | apply fold_left_preserves_valid; solve [eauto] ].
      rewrite <-fold_left_append by eauto.
      rewrite @append_divide with (H:=Heq).
      rewrite fold_left_resize. reflexivity. }
  Qed.

  Lemma pow2tree_generic_equiv
        {T}  {monad_laws : MonadLaws monad}
        (id : T)
        (op : T -> T -> T)
        (op_id_left : forall a : T, op id a = a)
        (op_id_right : forall a : T, op a id = a)
        (op_assoc :
          forall a b c : T,
            op a (op b c) = op (op a b) c)
        (circuit : T -> T -> cava T)
        (circuit_equiv :
          forall a b : T, circuit a b = ret (op a b))
        (default : T) (n : nat) :
    forall v,
      pow2tree_generic default n circuit v = ret (Vector.fold_left op id v).
  Proof.
    intros. apply pow2tree_generic_equiv' with (valid:=fun _ => True); auto using ForallV_trivial.
  Qed.

  (* Version of tree combinator that accepts all sizes by creating a tree out of
     the elements based on the closest power of two, and then tacking on the
     remaining elements one by one.

     The result will not be maximally efficient for non-powers of two; for
     example, for an and-tree with 6 elements i0..i5, this definition will
     produce:

     (((i0 & i1) & (i2 & i3)) & i4) & i5

     ...instead of &-ing i4 and i5 together before combining them with the
     tree. *)
  Definition tree_generic {m} {monad : Monad m} {A}
             (default : A) (circuit : A -> A -> m A) {n} (v : Vector.t A n) : m A :=
    let '(v1, v2) := Vector.splitat (2 ^ Nat.log2 n)
                                    (resize_default
                                       default (2 ^ Nat.log2 n + (n - 2 ^ Nat.log2 n))
                                       v) in
    tree_result <- pow2tree_generic default (Nat.log2 n) circuit v1 ;;
    foldLM circuit (to_list v2) tree_result.

  (* specialized to signal so default value can be automatically inferred *)
  Definition tree {m} {monad : Monad m} {t n}
                   (circuit: signal t * signal t -> cava (signal t))
                   (v : signal (Vec t n)) :
                   cava (signal t) :=
    v <- unpackV v ;;
    tree_generic defaultSignal (fun x y => circuit (x,y)) v.

  Lemma tree_generic_equiv' {T} {monad_laws : MonadLaws.MonadLaws monad}:
    forall (id : T) (op : T -> T -> T) (valid : T -> Prop),
      valid id ->
      (forall a b, valid a -> valid b -> valid (op a b)) ->
      (forall a : T, valid a -> op id a = a) ->
      (forall a : T, valid a -> op a id = a) ->
      (forall a b c : T, valid a -> valid b -> valid c ->
                    op a (op b c) = op (op a b) c) ->
      forall circuit : T -> T -> cava T,
        (forall a b : T, valid a -> valid b -> circuit a b = ret (op a b)) ->
        forall (default : T) (n : nat) (v : t T n),
          n <> 0 -> ForallV valid v ->
          tree_generic default circuit v = ret (Vector.fold_left op id v).
  Proof.
    cbv [tree_generic]; intros. repeat destruct_pair_let.
    assert (n = 2 ^ Nat.log2 n + (n - 2 ^ Nat.log2 n))
      by (apply Minus.le_plus_minus, Nat.log2_spec; Lia.lia).
    (* change the vector expression on the RHS to match LHS *)
    lazymatch goal with
      |- ?lhs = ?rhs =>
      lazymatch lhs with
        context [splitat ?n (resize_default ?d (?n + ?m) ?v)] =>
          let rhsF := lazymatch (eval pattern v in rhs) with
                      | ?F _ => F end in
          transitivity
            (rhsF
               (resize_default
                  d _
                  ((fst (splitat n (resize_default d (n + m) v)))
                      ++ snd (splitat n (resize_default d (n + m) v)))%vector))
      end
    end.
    2:{ erewrite <-append_splitat by (rewrite <-surjective_pairing; reflexivity).
        rewrite resize_default_resize_default, resize_default_id by Lia.lia.
        reflexivity. }
    pose proof (Nat.log2_pos n).
    destruct n; [ congruence | ]. cbn [ForallV] in *.
    repeat match goal with H : _ /\ _ |- _ => destruct H end.
    destruct n;[ subst; cbn in *; rewrite MonadLaws.bind_of_return by auto;
                 match goal with H : _ |- _ => rewrite H; solve [auto] end | ].
    erewrite pow2tree_generic_equiv' with (valid0:=valid) (id0:=id); eauto; [ | ].
    { rewrite MonadLaws.bind_of_return by auto.
      rewrite !fold_left_to_list, to_list_resize_default, to_list_append by lia.
      autorewrite with push_list_fold.
      erewrite foldLM_of_ret_valid with (validA:=valid) (validB:=valid);
        eauto; [ | ].
      { apply fold_left_invariant with (I:=valid); auto; [ ].
        intros *. rewrite InV_to_list_iff. intros.
        match goal with H : forall a b, _ -> _ -> valid (op a b) |- _ => apply H end;
          auto; [ ].
        eapply ForallV_forall; [ | solve [eauto]].
        intros. apply ForallV_splitat1.
        erewrite <-(resize_default_eq _ _ _ (ltac:(eassumption))).
        apply ForallV_resize. cbn [ForallV] in *; auto. }
      { apply ForallV_to_list_iff, ForallV_splitat2.
        erewrite <-(resize_default_eq _ _ _ (ltac:(eassumption))).
        apply ForallV_resize. cbn [ForallV] in *; auto. } }
    { intros. apply ForallV_splitat1.
      erewrite <-(resize_default_eq _ _ _ (ltac:(eassumption))).
      apply ForallV_resize. cbn [ForallV] in *; auto. }
  Qed.

  Lemma tree_generic_equiv {T} {monad_laws : MonadLaws.MonadLaws monad}:
    forall (id : T) (op : T -> T -> T),
      (forall a : T, op id a = a) ->
      (forall a : T, op a id = a) ->
      (forall a b c : T, op a (op b c) = op (op a b) c) ->
      forall circuit : T -> T -> cava T,
        (forall a b : T, circuit a b = ret (op a b)) ->
        forall (default : T) (n : nat) (v : t T n),
          n <> 0 ->
          tree_generic default circuit v = ret (Vector.fold_left op id v).
  Proof.
    intros. apply tree_generic_equiv' with (valid:=fun _ => True); auto using ForallV_trivial.
  Qed.

  Definition all {n} (v : signal (Vec Bit n)) : cava (signal Bit) :=
    match n with
    | 0 => ret one
    | _ => tree and2 v
    end.

  Fixpoint eqb {t : SignalType} : signal t -> signal t -> cava (signal Bit) :=
    match t as t0 return signal t0 -> signal t0 -> cava (signal Bit) with
    | Void => fun _ _ => ret one
    | Bit => fun x y => xnor2 (x, y)
    | ExternalType s => fun x y => ret one
    | Vec a n => fun x y : signal (Vec a n) =>
                  eq_results <- zipWith (fun '(a, b) => eqb a b) x y ;;
                  all eq_results
    end.
 End WithCava.