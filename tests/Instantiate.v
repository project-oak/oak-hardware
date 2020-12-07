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


Require Import Coq.Strings.Ascii Coq.Strings.String.
Require Import Coq.Lists.List.
Import ListNotations.

Require Import ExtLib.Structures.Monads.

Require Import Cava.Cava.
Require Import Cava.Monad.CavaMonad.

Local Open Scope list_scope.
Local Open Scope monad_scope.
Local Open Scope string_scope.

Section WithCava.
  Context {signal} `{Cava signal} `{Monad cava}.

  Definition nand2_gate (ab : signal Bit * signal Bit) : cava (signal Bit) :=
    x <- and2 ab ;;
    inv x.

  Definition nand2Interface
  := combinationalInterface
     "nand2"
     [mkPort "a" Bit; mkPort "b" Bit]
     [mkPort "c" Bit]
     [].

  Definition nand3_gate '(a, b, c) :=
      n1 <- instantiate nand2Interface nand2_gate (a, b) ;;
      instantiate nand2Interface nand2_gate (c, n1).   

End WithCava.

Definition nand3Interface
  := combinationalInterface
     "instantiate"
     [mkPort "a" Bit; mkPort "b" Bit; mkPort "c" Bit]
     [mkPort "d" Bit]
     [].

Definition instantiateNetlist := makeNetlist nand3Interface nand3_gate.

(* Test bench tables for generated SystemVerilog simulation test bench *)
Definition instantiate_tb_inputs : list (bool * bool * bool) :=
 [(false, false, false);
  (false, true, false);
  (true, false, true);
  (true, true, true)].

(* Compute expected outputs. *)
Definition instantiate_tb_expected_outputs : list bool :=
  map (fun i => combinational (nand3_gate i)) instantiate_tb_inputs.

Definition instantiate_tb :=
  testBench "instantiate_tb" nand3Interface instantiate_tb_inputs instantiate_tb_expected_outputs.

