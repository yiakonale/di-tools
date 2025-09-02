# Drive Inverter Tools

A collection of tools and scripts to aid in the component selection and analysis for drive inverters and other power electronics. Includes:

* Gate driver calculator
* Double-pulse test (DPT) calculator - COMING SOON
* DPT analyzer - COMING SOON

## How to use
### 1. Gate driver calculator

The gate driver calculator uses the following files:
* `class-defs/`
    * `gdic.m` - class definition for gate driver IC: contains parameters and methods for gate driver IC class
    * `pcba.m` - class definition for gate driver PCBA: contains parameters and methods for gate driver PCBA class
    * `powerstage.m` - class definition for powerstage: contains parameters and methods for powerstage class

* `params.m` - parameter assignment for gdic, pcba and powerstage objects: assigns values for all object parameters

* `gate-drive-calc.mlx` - gate drive calculator: interactive MATLAB live script for calculations

1. Take a look at the class definition files (`gdic.m`, `pcba.m`, `powerstage.m`) and familiarize yourself with each class and its associated parameters.
2. Open `params.m` and look under the Gate Driver, PCBA and Powerstage sections: Familiarize yourself with the existing objects and define new ones if desired.
3. Open `gate-drive-calc.mlx` live script. Select the target parameters at the top. Use the drop-down boxes to select the components, and the spinner boxes to define various parameters. Results should automatically be generated at every parameter change.

*Note: If new objects were defined in `params.m`, they must be added manually to the calculator. Double-click the drop-down box and add the new object.*
