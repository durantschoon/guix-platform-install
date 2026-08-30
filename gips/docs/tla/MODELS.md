# TLA+ Modeling Guide

This directory contains TLA+ specifications for formal verification of GIPS's distributed systems properties.

## Optimization: Reducing State Space Explosion

When modeling distributed systems, the state space can quickly explode, causing the TLC model checker to run out of memory or take an impractically long time to run.

If you experience state space explosion, a highly recommended optimization is to use **Symmetry Sets**. TLC can recognize when the specific identity of an element (like a node or a package) doesn't matter, only its relationship to other elements. By using Symmetry, TLC treats equivalent states as a single state, shrinking the search space factorially.

### How to use Symmetry in TLC

1. **Declare Model Values in `.cfg`:** Symmetry requires the constants to be explicitly declared as TLC "Model Values" in the configuration file, rather than string literals in the `.tla` file. Update your `.cfg` file to assign the elements to themselves and define the set:

   ```ini
   CONSTANTS
       pkgA = pkgA
       pkgB = pkgB
       Packages = {pkgA, pkgB}
   
   SYMMETRY
       Symmetry
   ```

2. **Define the Symmetry Operator in `.tla`:** In your TLA+ specification, define the `Symmetry` operator using the `Permutations` function (which requires `EXTENDS TLC`):

   ```tla
   \* Symmetry Optimization to reduce state space exploration
   Symmetry == Permutations(Packages)
   ```

Doing this tells TLC that `pkgA` and `pkgB` are entirely interchangeable from a structural perspective, allowing it to drastically prune identical execution branches.
