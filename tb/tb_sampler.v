`timescale 1ps/1ps
// Stage-1 integration: 3-FF samplers + MOD-1000 counter + BVM.
// Nominal sampler 10 MHz, input 9.99000999 MHz (100100 ps period).
// 20 ns B delay gives ~200 count A-B modular phase difference.
// The 100100 ps integer-period approximation makes the beat ~1001 cycles.
module tb_sampler;
    reg clk = 1'b0;
    reg clk_a = 1'b0;
    reg rst = 1'b1;
    wire clk_b_delayed;
    assign #20000 clk_b_delayed = clk_a;
    always #50000 clk = ~clk;
    always #50050 clk_a = ~clk_a;

    wire [9:0] zero_a, zero_b, step_a, step_b;
    wire zero_va, zero_vb, step_va, step_vb;
    ddmtd_stage1 dut_zero (
        .clk(clk), .rst(rst), .clk_a(clk_a), .clk_b(clk_a),
        .bvm_threshold(4'd4), .tag_a(zero_a), .tag_b(zero_b),
        .tag_a_valid(zero_va), .tag_b_valid(zero_vb)
    );
    ddmtd_stage1 dut_step (
        .clk(clk), .rst(rst), .clk_a(clk_a), .clk_b(clk_b_delayed),
        .bvm_threshold(4'd4), .tag_a(step_a), .tag_b(step_b),
        .tag_a_valid(step_va), .tag_b_valid(step_vb)
    );

    integer cycles = 0;
    integer count_za = 0, count_zb = 0, count_sa = 0, count_sb = 0;
    integer last_za = -1, last_zb = -1, last_sa = -1, last_sb = -1;
    integer errors = 0, checked_pairs = 0;
    integer phase_diff;
    reg [9:0] held_a, held_b;
    reg fresh_a = 0, fresh_b = 0;

    function integer circular_error;
        input integer got, want;
        integer d;
        begin
            d = got - want;
            if (d > 500) d = d - 1000;
            if (d < -500) d = d + 1000;
            circular_error = d;
        end
    endfunction

    // Read registered DUT outputs after NBA updates. One tag expected
    // approximately every 1000 sampler cycles, after initial acquisition.
    always @(posedge clk) begin
        #1;
        if (!rst) begin
            cycles = cycles + 1;
            if (dut_zero.free_cntr > 999 || dut_step.free_cntr > 999) begin
                $display("FAIL: counter outside MOD-1000 range");
                errors = errors + 1;
            end
            if (zero_va) begin
                if (last_za >= 0 && (cycles-last_za < 997 || cycles-last_za > 1005)) begin
                    $display("FAIL: zero A cadence %0d", cycles-last_za); errors = errors+1;
                end
                last_za = cycles; count_za = count_za + 1;
                if (!zero_vb || zero_a !== zero_b) begin
                    $display("FAIL: identical input tags A=%0d B=%0d validB=%b", zero_a, zero_b, zero_vb);
                    errors = errors + 1;
                end
            end
            if (zero_vb) begin
                count_zb = count_zb + 1;
                if (last_zb >= 0 && (cycles-last_zb < 997 || cycles-last_zb > 1005)) begin
                    $display("FAIL: zero B cadence %0d", cycles-last_zb); errors = errors+1;
                end
                last_zb = cycles;
            end
            if (step_va) begin
                count_sa = count_sa + 1;
                if (last_sa >= 0 && (cycles-last_sa < 997 || cycles-last_sa > 1005)) begin
                    $display("FAIL: step A cadence %0d", cycles-last_sa); errors = errors+1;
                end
                last_sa = cycles; held_a = step_a; fresh_a = 1;
            end
            if (step_vb) begin
                count_sb = count_sb + 1;
                if (last_sb >= 0 && (cycles-last_sb < 997 || cycles-last_sb > 1005)) begin
                    $display("FAIL: step B cadence %0d", cycles-last_sb); errors = errors+1;
                end
                last_sb = cycles; held_b = step_b; fresh_b = 1;
            end
            if (fresh_a && fresh_b) begin
                phase_diff = (held_a + 1000 - held_b) % 1000;
                // Ignore first two pairs while both BVM FSMs acquire.
                if (checked_pairs >= 2 && (circular_error(phase_diff, 200) > 3 || circular_error(phase_diff, 200) < -3)) begin
                    $display("FAIL: 20ns offset phase A=%0d B=%0d diff=%0d expected~200", held_a, held_b, phase_diff);
                    errors = errors + 1;
                end
                checked_pairs = checked_pairs + 1;
                fresh_a = 0; fresh_b = 0;
            end
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst = 0;
        // About 12 beat periods, sufficient for steady-state checks.
        repeat (12500) @(negedge clk);
        $display("SAMPLER SUMMARY: zeroA=%0d zeroB=%0d delayedA=%0d delayedB=%0d pairs=%0d errors=%0d",
                 count_za, count_zb, count_sa, count_sb, checked_pairs, errors);
        if (count_za < 9 || count_zb < 9 || count_sa < 9 || count_sb < 9 || checked_pairs < 9)
            $fatal(1, "Insufficient Stage-1 tags");
        if (errors != 0) $fatal(1, "Stage-1 sampler integration FAILED");
        $display("PASS: Stage-1 sampler + BVM integration");
        $finish;
    end
    initial begin
        #1500000000;
        $fatal(1, "Sampler integration timeout");
    end
endmodule
