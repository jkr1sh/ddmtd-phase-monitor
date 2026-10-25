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

    // Passive monitors (enabled only for characterization builds).
`ifdef DDMTD_LOGGING
    ddmtd_monitor #(.CASE_ID(0)) mon0 (
        .clk(clk), .rst(rst), .threshold(in0[5:2]),
        .tag_a(dut0.tag_a), .tag_b(dut0.tag_b),
        .tag_a_valid(dut0.tag_a_valid), .tag_b_valid(dut0.tag_b_valid),
        .pair_tag_a(dut0.pair_tag_a), .pair_tag_b(dut0.pair_tag_b),
        .pair_valid(dut0.pair_valid), .pair_reinit(dut0.pair_reinit),
        .avg_phase(dut0.avg_phase), .avg_valid(dut0.avg_valid),
        .pair_error(dut0.pair_error), .tracking_locked(dut0.tracking_locked));
    ddmtd_monitor #(.CASE_ID(20)) mon20 (
        .clk(clk), .rst(rst), .threshold(in20[5:2]),
        .tag_a(dut20.tag_a), .tag_b(dut20.tag_b),
        .tag_a_valid(dut20.tag_a_valid), .tag_b_valid(dut20.tag_b_valid),
        .pair_tag_a(dut20.pair_tag_a), .pair_tag_b(dut20.pair_tag_b),
        .pair_valid(dut20.pair_valid), .pair_reinit(dut20.pair_reinit),
        .avg_phase(dut20.avg_phase), .avg_valid(dut20.avg_valid),
        .pair_error(dut20.pair_error), .tracking_locked(dut20.tracking_locked));
    ddmtd_monitor #(.CASE_ID(95)) mon95 (
        .clk(clk), .rst(rst), .threshold(in95[5:2]),
        .tag_a(dut95.tag_a), .tag_b(dut95.tag_b),
        .tag_a_valid(dut95.tag_a_valid), .tag_b_valid(dut95.tag_b_valid),
        .pair_tag_a(dut95.pair_tag_a), .pair_tag_b(dut95.pair_tag_b),
        .pair_valid(dut95.pair_valid), .pair_reinit(dut95.pair_reinit),
        .avg_phase(dut95.avg_phase), .avg_valid(dut95.avg_valid),
        .pair_error(dut95.pair_error), .tracking_locked(dut95.tracking_locked));
`endif

    // Independent serial decoding against published averages.
`ifdef DDMTD_LOGGING
    ddmtd_uart_checker #(.CASE_ID(0)) uart_check0 (
        .clk(clk), .rst(rst), .avg_phase(out0[9:0]),
        .avg_valid(out0[10]), .tx(out0[11]));
    ddmtd_uart_checker #(.CASE_ID(20)) uart_check20 (
        .clk(clk), .rst(rst), .avg_phase(out20[9:0]),
        .avg_valid(out20[10]), .tx(out20[11]));
    ddmtd_uart_checker #(.CASE_ID(95)) uart_check95 (
        .clk(clk), .rst(rst), .avg_phase(out95[9:0]),
        .avg_valid(out95[10]), .tx(out95[11]));
`endif

`ifdef DDMTD_LOGGING
    initial $display("DEBUG: DDMTD_LOGGING IS ENABLED");
`else
    initial $display("DEBUG: DDMTD_LOGGING IS DISABLED");
`endif

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
`ifdef DDMTD_LOGGING
        uart_check0.check_complete();
        uart_check20.check_complete();
        uart_check95.check_complete();
`endif
        if (errors) $fatal(1, "DDMTD integration FAILED");
        $display("PASS: DDMTD integration (0, 20, 95 ns)");
        $finish;
    end
    initial begin
        #14000000;
        $fatal(1, "DDMTD integration timeout");
    end
endmodule
