# multiply
A formally verified integer multiply softcore with area of O(N*M*logN) and time O(logN) complexity

Use multiply.v with the following interface: // out_C = in_A * in_B

`input clk, reset;`

`input in_valid; // to signify that in_A, in_B are valid, multiplication process can start`

`input signed [(A_WIDTH-1):0] in_A;`

`input signed [(B_WIDTH-1):0] in_B;`

`output signed [(A_WIDTH+B_WIDTH-1):0] out_C;`

`output reg out_valid; // to signify that out_C is valid, multiplication finished`
