`timescale 1ns/1ps
// Integrated nominal-clock DDMTD test. No analog metastability model.
module tb_ddmtd;
    reg clk = 0;
    always #50 clk = ~clk; // 10 MHz
    reg rst = 1;
    reg clk_a = 0;
    reg clk_b0 = 0, clk_b20 = 0, clk_b95 = 0;
    wire [13:0] out0, out20, out95;
    wire [13:0] in0  = {8'b0, 4'd4, clk_b0,  clk_a};
    wire [13:0] in20 = {8'b0, 4'd4, clk_b20, clk_a};
    wire [13:0] in95 = {8'b0, 4'd4, clk_b95, clk_a};

    ddmtd dut0 (.clk(clk), .rst(rst), .in(in0), .out(out0));
    ddmtd dut20(.clk(clk), .rst(rst), .in(in20), .out(out20));
    ddmtd dut95(.clk(clk), .rst(rst), .in(in95), .out(out95));

    // 9.99001 MHz nominal: input period = 100100 ps.
    always #50.050 clk_a = ~clk_a;
    always #50.050 clk_b0 = ~clk_b0;
    initial begin
        #20; // 20 ns input B delay
        forever #50.050 clk_b20 = ~clk_b20;
    end
    initial begin
        #95; // 95 ns input B delay (near circular boundary)
        forever #50.050 clk_b95 = ~clk_b95;
    end

    integer errors = 0;
    integer outputs0 = 0, outputs20 = 0, outputs95 = 0;
    integer pairs0 = 0, pairs20 = 0, pairs95 = 0;
    integer circular_err;
    function integer circ_error;
        input integer got, wanted;
        integer diff;
        begin
            diff = got - wanted;
            if (diff < 0) diff = -diff;
            if (diff > 500) diff = 1000 - diff;
            circ_error = diff;
        end
    endfunction

    // Check outputs after nonblocking assignments settle.
    always @(posedge clk) begin
        #1;
        if (dut0.pair_valid) pairs0 = pairs0 + 1;
        if (dut20.pair_valid) pairs20 = pairs20 + 1;
        if (dut95.pair_valid) pairs95 = pairs95 + 1;
        if (out0[10]) begin
            outputs0 = outputs0 + 1;
            circular_err = circ_error(out0[9:0], 0);
            if (circular_err > 3) begin
                errors = errors + 1;
                $display("FAIL zero-delay phase=%0d error=%0d", out0[9:0], circular_err);
            end
        end
        if (out20[10]) begin
            outputs20 = outputs20 + 1;
            circular_err = circ_error(out20[9:0], 200);
            if (circular_err > 4) begin
                errors = errors + 1;
                $display("FAIL 20ns phase=%0d expected~200 error=%0d", out20[9:0], circular_err);
            end
        end
        if (out95[10]) begin
            outputs95 = outputs95 + 1;
            circular_err = circ_error(out95[9:0], 950);
            if (circular_err > 5) begin
                errors = errors + 1;
                $display("FAIL 95ns phase=%0d expected~950 error=%0d", out95[9:0], circular_err);
            end
        end
        if (out0[12] || out20[12] || out95[12]) begin
            errors = errors + 1;
            $display("FAIL unexpected watchdog/pairing fault t=%0t", $time);
            $fatal(1, "Unexpected pairing fault");
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst = 0;
        #12000000; // 12 ms: allow acquisition and multiple averages
        $display("INTEGRATION SUMMARY: pairs=%0d/%0d/%0d averages=%0d/%0d/%0d errors=%0d",
                 pairs0, pairs20, pairs95, outputs0, outputs20, outputs95, errors);
        if (outputs0 < 2 || outputs20 < 2 || outputs95 < 2) begin
            $display("FAIL insufficient averaged outputs");
            errors = errors + 1;
        end
        if (errors) $fatal(1, "DDMTD integration FAILED");
        $display("PASS: DDMTD integration (0, 20, 95 ns)");
        $finish;
    end
    initial begin
        #14000000;
        $fatal(1, "DDMTD integration timeout");
    end
endmodule
