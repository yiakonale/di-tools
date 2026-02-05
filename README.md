# Drive Inverter Tools

A collection of tools and scripts to aid in the component selection and analysis for drive inverters and other power electronics. Includes:

* Gate driver calculator
* Discharge resistor calculator
* Double-pulse test (DPT) calculator - COMING SOON
* DPT analyzer - COMING SOON

## How to use
### 1. Gate driver calculator

The gate driver calculator uses the following files:
* `class-defs/`
    * `gdic.m` - class definition for gate driver IC: contains parameters and methods for gate driver IC class
    * `pcba.m` - class definition for gate driver PCBA: contains parameters and methods for gate driver PCBA class
    * `powerstage.m` - class definition for powerstage: contains parameters and methods for powerstage class

* `load_params.m` - parameter assignment for gdic, pcba and powerstage objects: assigns values for all object parameters

* `gate_drive_calc.mlx` - gate drive calculator: interactive MATLAB live script for calculations

1. Take a look at the class definition files (`gdic.m`, `pcba.m`, `powerstage.m`) and familiarize yourself with each class and its associated parameters.
2. Open `load_params.m` and look under the Gate Driver, PCBA and Powerstage sections: Familiarize yourself with the existing objects and define new ones if desired.
3. Open `gate_drive_calc.mlx` live script. Select the target parameters at the top. Use the drop-down boxes to select the components, and the spinner boxes to define various parameters. Results should automatically be generated at every parameter change.

*Note: If new objects were defined in `load_params.m`, they must be added manually to the calculator. Double-click the drop-down box and add the new object.*

### 2. Discharge resistor calculator

* `discharge_res_calc.mlx` - calculator intended for analyzing resistor arrays used to safely discharge high-voltages.

You can define individual package resistance, series and parallel configuration and input voltage, and calculate per resistor voltage drop, current and power dissipated, as well as equivalent resistance, total current and power. Optionally, you can define a discharge capacitance to calculate the RC time constant and time taken to discharge the bus to low-voltage.
