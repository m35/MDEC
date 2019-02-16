module MDEC(
	// System
	input			clk,
	input			i_nrst,

	// Setup
	input [3:0]		i_bitSetupDepth, // [Bit 1..0 = (0=4bit, 1=8bit, 2=24bit, 3=15bit), Bit 2=(0=Unsigned, 1=Signed) , Bit 3= (0=Clear, 1=Set) (for 15bit depth only)
	input			i_bit15Set,
	input			i_bitSigned,
	
	// RLE Stream
	input			i_dataWrite,
	input [15:0]	i_dataIn,
	
	// Loading of COS Table (Linear, no zigzag)
	input			i_cosWrite,
	input	[ 5:0]	i_cosIndex,
	input	[15:0]	i_cosVal,
	
	// Loading of quant Matrix
	input			i_quantWrt,
	input	[6:0]	i_quantValue,
	input	[5:0]	i_quantAdr,
	input			i_quantTblSelect,

	output			o_stillLoading,
	output			o_stillIDCT,
	output			o_stillPushingPixel,
	
	output			db_coefWrt,
	output	[9:0]	db_coefValue,
	output			db_coefDC,
	output	[5:0]	db_coefIdx,
	output	[2:0]	db_coefBlk,
	output			db_coefComplete,
	
	output  [1:0]	o_depth,
	output			o_pixelOut,
	output  [7:0]   o_pixelAddress,		// 16x16 or 8x8 [yyyyxxxx] or [0yyy0xxx]
	output  [7:0]	o_rComp,
	output  [7:0]	o_gComp,
	output  [7:0]	o_bComp
);

	// Instance Stream Decoder
	wire YOnly = !i_bitSetupDepth[1];
	wire busyIDCT;
	
	assign o_stillIDCT = busyIDCT;
	
	// [TODO] o_stillLoading, o_stillPushingPixel.
	// [TODO] : STOP pushing input when IDCT busy. (or even pixel ? see later)
	//
	
	streamInput streamInput_inst(
		.clk			(clk),
		.i_nrst			(i_nrst),
		.i_dataWrite	(i_dataWrite),
		.i_dataIn		(i_dataIn),
		.i_YOnly		(YOnly),
		
		.o_dataWrt		(dataWrt_b),
		.o_dataOut		(dataOut_b),
		.o_scale		(scale_b),
		.o_isDC			(isDC_b),
		.o_index		(index_b),				// Linear order for storage
		.o_zagIndex		(zagIndex_b),			// Needed because Quant table is in zigzag order, avoid decode into linear.
		.o_fullBlockType(fullBlockType_b),
		.o_blockNum		(blockNum_b),			// Need to propagate info with data, easier for control logic.
		.o_blockComplete(blockComplete_b)
	);
	
	wire 			dataWrt_b;
	wire [9:0]		dataOut_b;
	wire [5:0]		scale_b;
	wire			isDC_b;
	wire [5:0]		index_b;			
	wire [5:0]		zagIndex_b;		
	wire			fullBlockType_b;
	wire [2:0]		blockNum_b;		
	wire			blockComplete_b;

	assign			db_coefWrt   	=dataWrt_b;
	assign			db_coefValue 	=dataOut_b;
	assign			db_coefDC		=isDC_b;
	assign			db_coefIdx		=zagIndex_b;
	assign			db_coefBlk		= blockNum_b;
	assign			db_coefComplete	= blockComplete_b;
	
	// Instance Coef Multiplier
	computeCoef ComputeCoef_inst (
		.i_clk			(clk),
		.i_nrst			(i_nrst),

		.i_dataWrt		(dataWrt_b),
		.i_dataIn		(dataOut_b),
		.i_scale		(scale_b),
		.i_isDC			(isDC_b),
		.i_index		(index_b),
		.i_zagIndex		(zagIndex_b),			// Needed because Quant table is in zigzag order, avoid decode into linear.
		.i_fullBlockType(fullBlockType_b),
		.i_blockNum		(blockNum_b),
		.i_matrixComplete(blockComplete_b),

		// Quant Table Loading
		.i_quantWrt		(i_quantWrt),
		.i_quantValue	(i_quantValue),
		.i_quantAdr		(i_quantAdr),
		.i_quantTblSelect(i_quantTblSelect),
		
		// Write output (2 cycle latency from loading)
		.o_write			(write_c),
		.o_writeIdx			(writeIdx_c),
		.o_blockNum			(blockNum_c),
		.o_coefValue		(coefValue_c),
		.o_matrixComplete	(matrixComplete_c)
	);

	wire		write_c;
	wire [5:0]	writeIdx_c;
	wire [2:0]	blockNum_c;
	wire [19:0]	coefValue_c;
	wire		matrixComplete_c;
	
	reg  [2:0]  rBlockNum; // [TODO] store block num of first load (DC).
	
	// Instance IDCT

	IDCT IDCTinstance (
		// System
		.clk				(clk),
		.i_nrst				(i_nrst),
		// Coefficient input
		.i_write			(write_c),
		.i_writeIdx			(writeIdx_c),
		.i_blockNum			(blockNum_c),
		.i_coefValue		(coefValue_c),
		.i_matrixComplete	(matrixComplete_c),

		// Loading of COS Table (Linear, no zigzag)
		.i_cosWrite			(i_cosWrite),
		.i_cosIndex			(i_cosIndex),
		.i_cosVal			(i_cosVal),
		
		// Output in order value out
		.o_value			(value_d),
		.o_writeValue		(writeValue_d),
		.o_busyIDCT			(busyIDCT),
		.o_writeIndex		(writeIndex_d)
	);
	
	wire	[22:0]	value_d;
	wire 			writeValue_d;
	wire	 [5:0]	writeIndex_d;

	// --------------------------------------------------
	// Select Cr,Cb write or direct input to YUV
	// --------------------------------------------------
	wire writeY  = writeValue_d && (rBlockNum[2] | rBlockNum[1]);
	wire writeCr = writeValue_d && !writeY && (!rBlockNum[0]);	// When not Y, and blocknumber = 0
	wire writeCb = writeValue_d && !writeY && (rBlockNum[0]);	// When not Y, and blocknumber = 1
	
	// 000 : Y0 Ignored
	// 001 : Y1 Ignored
	// 010 : Y0
	// 011 : Y1
	// 100 : Y2
	// 101 : Y3
	// 111 : Y3 (Y Only mode)
	wire [1:0] YBlockNum = { rBlockNum[2],rBlockNum[0] };
	
	// --------------------------------------------------
	//  Cr / Cb Memory : 8x8
	// --------------------------------------------------
	// Public Shared (declared already)
	wire		 [5:0]	readAdrCrCbTable;
	//
	// Public READ Value
	wire		[22:0]	readCrValue;
	wire		[22:0]	readCbValue;
	// Public WRITE VALUE
	reg signed	[22:0]	CrTable[63:0];
	reg signed	[22:0]	CbTable[63:0];
	reg			 [5:0]	readAdrCrCbTable_reg;
	
	always @ (posedge clk)
	begin
		if (writeCr)
		begin
			CrTable[writeIndex_d] <= value_d;
		end
		if (writeCb)
		begin
			CbTable[writeIndex_d] <= value_d;
		end
		readAdrCrCbTable_reg<= readAdrCrCbTable;
	end
	assign readCrValue = CrTable[readAdrCrCbTable_reg];
	assign readCbValue = CbTable[readAdrCrCbTable_reg];
	//--------------------------------------------------------
	
/*
	// Instance YUV Converter
	YUV2RGBCompute YUV2RGBCompute_instance (
		// System
		.clk		(clk),
		.i_nrst		(i_nrst),

		// Input
		.i_wrt		(writeY),
		.i_YOnly	(YOnly),
		.i_writeIdx	(writeIndex_d),
		.i_valueY	(value_d),
		.i_YBlockNum(YBlockNum),

		// Read Cr
		// Read Cb
		.o_readAdr	(readAdrCrCbTable),
		.i_valueCr	(readCrValue),
		.i_valueCb	(readCbValue),
		
		// Output in order value out
		.o_wPix		(o_pixelOut),
		.o_pix		(o_pixelAddress),
		.o_r		(o_rComp),
		.o_g		(o_gComp),
		.o_b		(o_bComp)
	);
*/
endmodule