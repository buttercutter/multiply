module multiply #(parameter A_WIDTH=16, B_WIDTH=16)
(clk, reset, in_valid, out_valid, in_A, in_B, out_C); // C=A*B

`ifdef FORMAL
parameter A_WIDTH = 6;
parameter B_WIDTH = 6;
`endif

input clk, reset;
input in_valid; // to signify that in_A, in_B are valid, multiplication process can start
input signed [(A_WIDTH-1):0] in_A;
input signed [(B_WIDTH-1):0] in_B;
output signed [(A_WIDTH+B_WIDTH-1):0] out_C;
output reg out_valid; // to signify that out_C is valid, multiplication finished

/* 
   This signed multiplier code architecture is a combination of row adder tree and 
   modified baugh-wooley algorithm, thus requires an area of O(N*M*logN) and time O(logN)
   with M, N being the length(bitwidth) of the multiplicand and multiplier respectively

   see https://i.imgur.com/NaqjC6G.png (1+1=10 in binary, but it is denoted as 2 here) or 
   Row Adder Tree Multipliers in http://www.andraka.com/multipli.php or
   https://pdfs.semanticscholar.org/415c/d98dafb5c9cb358c94189927e1f3216b7494.pdf#page=10
   regarding the mechanisms within all layers

   In terms of fmax consideration: In the case of an adder tree, the adders making up the levels
   closer to the input take up real estate (remember the structure of row adder tree).  As the 
   size of the input multiplicand bitwidth grows, it becomes more and more difficult to find a
   placement that does not use long routes involving multiple switch nodes for FPGA.  The result
   is the maximum clocking speed degrades quickly as the size of the bitwidth grows.

   For signed multiplication, see also modified baugh-wooley algorithm for trick in skipping 
   sign extension (implemented as verilog example in https://www.dsprelated.com/showarticle/555.php),
   thus smaller final routed silicon area.
   https://stackoverflow.com/questions/54268192/understanding-modified-baugh-wooley-multiplication-algorithm/

   All layers are pipelined, so throughput = one result for each clock cycle 
   but each multiplication result still have latency = NUM_OF_INTERMEDIATE_LAYERS 
*/


// The multiplication of two numbers is equivalent to adding as many copies of one 
// of them, the multiplicand, as the value of the other one, the multiplier.
// Therefore, multiplicand always have the larger width compared to multipliers

localparam SMALLER_WIDTH = (A_WIDTH <= B_WIDTH) ? A_WIDTH : B_WIDTH;
localparam LARGER_WIDTH = (A_WIDTH > B_WIDTH) ? A_WIDTH : B_WIDTH;

wire [(LARGER_WIDTH-1):0] MULTIPLICAND = (A_WIDTH > B_WIDTH) ? in_A : in_B ;
wire [(SMALLER_WIDTH-1):0] MULTIPLIER = (A_WIDTH <= B_WIDTH) ? in_A : in_B ;


// to keep the values of multiplicand and multiplier before the multiplication finishes 
reg signed [(LARGER_WIDTH-1):0] MULTIPLICAND_reg;
reg signed [(SMALLER_WIDTH-1):0] MULTIPLIER_reg;

always @(posedge clk)
begin
	if(reset) begin
		MULTIPLICAND_reg <= 0;
		MULTIPLIER_reg <= 0;
	end

	else if(in_valid && !multiply_had_started) 
	begin
		MULTIPLICAND_reg <= MULTIPLICAND;
		MULTIPLIER_reg <= MULTIPLIER;
	end
end


localparam NUM_OF_INTERMEDIATE_LAYERS = $clog2(SMALLER_WIDTH);


/*Binary multiplications and additions for partial products rows*/

// first layer has "SMALLER_WIDTH" entries of data of width "LARGER_WIDTH"
// This resulted in a binary tree with faster vertical addition processes as we have 
// lesser (NUM_OF_INTERMEDIATE_LAYERS) rows to add

// intermediate partial product rows additions
// Imagine a rhombus of height of "SMALLER_WIDTH" and width of "LARGER_WIDTH"
// being re-arranged into binary row adder tree
// such that additions can be done in O(logN) time

reg signed [(A_WIDTH+B_WIDTH-1):0] middle_layers[NUM_OF_INTERMEDIATE_LAYERS:0][0:(SMALLER_WIDTH-1)];

generate // duplicates the leafs of the binary tree

	// layer #0 means the youngest leaf, all the initial partial products are at this layer
	// layer #NUM_OF_INTERMEDIATE_LAYERS means the tree trunk, the final result is here
	genvar layer;

  	for(layer=0; layer<=NUM_OF_INTERMEDIATE_LAYERS; layer=layer+1) begin: intermediate_layers

		integer pp_index; // leaf index within each layer of the tree

		always @(posedge clk)
		begin
			if(reset) 
			begin
				for(pp_index=0; pp_index<SMALLER_WIDTH ; pp_index=pp_index+1)
					middle_layers[layer][pp_index] <= 0;
			end

			else begin		
	
				if(layer == 0)  // all partial products rows are in this first layer
				begin				
					// generation of partial products rows
					for(pp_index=0; pp_index<SMALLER_WIDTH ; pp_index=pp_index+1)
						middle_layers[layer][pp_index] <= MULTIPLIER[pp_index] ? MULTIPLICAND:0;	
						
					// see modified baugh-wooley algorithm: https://i.imgur.com/VcgbY4g.png from
					// page 122 of book: Ultra-Low-Voltage Design of Energy-Efficient Digital Circuits
					for(pp_index=0; pp_index<(SMALLER_WIDTH-1) ; pp_index=pp_index+1) // MSB inversion
						middle_layers[layer][pp_index][LARGER_WIDTH-1] <= 
					    (MULTIPLICAND[LARGER_WIDTH-1] & MULTIPLIER[pp_index]) ? 0:1;
						
					for(pp_index=0; pp_index<(LARGER_WIDTH-1) ; pp_index=pp_index+1) // last partial product row inversion
						middle_layers[layer][SMALLER_WIDTH-1][pp_index] <= 
						(MULTIPLICAND[pp_index] & MULTIPLIER[SMALLER_WIDTH-1]) ? 0:1;

					middle_layers[layer][SMALLER_WIDTH-1][LARGER_WIDTH] <= 1;
				end
				
				// Why    << (1<<(layer-1))    ?
				// Consider the case when SMALLER_WIDTH is not of power of two (2^x)
				// we need to fit in SMALLER_WIDTH rows of partial product into the binary tree
				else if(layer == NUM_OF_INTERMEDIATE_LAYERS)
				begin
						middle_layers[layer][0] <= 
						middle_layers[layer-1][0] +
    	          	   (middle_layers[layer-1][1] << (1<<(NUM_OF_INTERMEDIATE_LAYERS-1)));					
				end
				
				// adding the partial product rows according to row adder (binary) tree architecture
				else begin
					for(pp_index=0; pp_index< $ceil($itor(SMALLER_WIDTH)/(1 << layer)) ; pp_index=pp_index+1)
					begin
						if(pp_index==0)
							middle_layers[layer][pp_index] <=
							middle_layers[layer-1][0] +
		              	   (middle_layers[layer-1][1] << (1<<(layer-1)));

						else begin
							// ensures that the previous layer has valid item to be added
							if(((pp_index<<1)+1) < $ceil($itor(SMALLER_WIDTH)/(1 << (layer-1))))
							 middle_layers[layer][pp_index] <=
							 middle_layers[layer-1][pp_index<<1] +
		              		(middle_layers[layer-1][(pp_index<<1) + 1] << (1<<(layer-1)));

							// take care of odd value of multiplier (SMALLER_WIDTH) 
							// such as 3, so that the last odd partial row is forwarded
							// to the next layer for addition
							else 
							 middle_layers[layer][pp_index] <=
							 middle_layers[layer-1][pp_index<<1];
						end
		            end
		      	end
			end
		end
	end

endgenerate


assign out_C = (reset || (MULTIPLICAND_reg == 0) || (MULTIPLIER_reg == 0)) ? 0 :
			 	middle_layers[NUM_OF_INTERMEDIATE_LAYERS][0] 
				+ ((1 << (LARGER_WIDTH-1)) + (1 << (SMALLER_WIDTH-1)));

/*
This paragraph is to discuss the shortcomings of the published modified baugh-wooley algorithm
which does not handle the case where A_WIDTH != B_WIDTH

This code above had implemented the countermeasure described in https://i.imgur.com/8U3pX3C.png

The countermeasure does not do "To build a 6x4 multplier you can build a 6x6 multiplier, but replicate 
the sign bit of the short word 3 times, and ignore the top 2 bits of the result." , instead it uses 
some smart tricks/logic discussed in https://www.reddit.com/r/algorithms/comments/ar40e4/modified_baughwooley_multiplication_algorithm_for/egl46ml

Please use pencil and paper method (and signals waveform) to verify or understand this.
I did not do a rigorous math proof on this countermeasure.

The countermeasure is considered successful when assert(out_C == (MULTIPLICAND_reg * MULTIPLIER_reg)); 
passed during cover() verification
*/



/*Checking if the final multiplication result is ready or not*/

reg [($clog2(NUM_OF_INTERMEDIATE_LAYERS)-1):0] out_valid_counter; // to track the multiply stages
reg multiply_had_started;

always @(posedge clk)
begin
	if(reset) 
	begin
		multiply_had_started <= 0;
		out_valid <= 0;
		out_valid_counter <= 0;
	end

	else if(out_valid_counter == NUM_OF_INTERMEDIATE_LAYERS-1) begin
		multiply_had_started <= 0;
		out_valid <= 1;
		out_valid_counter <= 0;
	end
	
	else if(in_valid && !multiply_had_started) begin
		multiply_had_started <= 1;
		out_valid <= 0; // for consecutive multiplication
		out_valid_counter <= 0;
	end
	
	else begin
		out_valid <= 0;
		if(multiply_had_started) out_valid_counter <= out_valid_counter + 1;
	end
end


`ifdef FORMAL

reg sign_bit;

always @(posedge clk)
begin
	if(in_valid && !multiply_had_started)
		sign_bit <= MULTIPLICAND[LARGER_WIDTH-1] ^ MULTIPLIER[SMALLER_WIDTH-1];
end

initial assume(reset);
initial assume(in_valid == 0);


always @(posedge clk)
begin
	if(reset) assert(out_C == 0);
	
	else if(out_valid) 
	begin
		if((MULTIPLICAND_reg == 0) || (MULTIPLIER_reg == 0)) 
			assert(out_C == 0);

		else begin
			assert(out_C == (MULTIPLICAND_reg * MULTIPLIER_reg));
			assert(out_C[A_WIDTH+B_WIDTH-1] == sign_bit);
		end
	end
end

`endif

`ifdef FORMAL

wire signed [(A_WIDTH-1):0] negative_value_for_A = $anyconst;
wire signed [(A_WIDTH-1):0] positive_value_for_A = $anyconst;

wire signed [(B_WIDTH-1):0] negative_value_for_B = $anyconst;
wire signed [(B_WIDTH-1):0] positive_value_for_B = $anyconst;

always @(posedge clk)
begin
	assume(negative_value_for_A < 0);
	assume(negative_value_for_B < 0);

	assume(positive_value_for_A > 0);
	assume(positive_value_for_B > 0);
	
	cover(in_valid && (in_A == positive_value_for_A) && (in_B == positive_value_for_B));
	cover(in_valid && (in_A == negative_value_for_A) && (in_B == positive_value_for_B));
	cover(in_valid && (in_A == positive_value_for_A) && (in_B == negative_value_for_B));
	cover(in_valid && (in_A == negative_value_for_A) && (in_B == negative_value_for_B));
	//cover(in_valid && (in_A == -2) && (in_B == -22));

	cover(out_valid);
end

`endif

endmodule
