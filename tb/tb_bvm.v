`timescale 1ns/1ps
// Deterministic, self-checking BVM unit test (not end-to-end DDMTD).
module tb_bvm;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, sample = 0;
    reg [3:0] threshold = 4;
    reg [9:0] time_count = 0;
    wire [9:0] tag;
    wire tag_valid;
    integer checks = 0, errors = 0, pulses = 0;
    integer first_high, later_zeros, expected;
    ddmtd_bvm_tagger dut(.clk(clk), .rst(rst), .sample(sample),
        .time_count(time_count), .threshold(threshold),
        .tag(tag), .tag_valid(tag_valid));

    task tick;
        input integer value;
        begin
            @(negedge clk);
            sample = value;
            @(posedge clk); #1;
            if (tag_valid) pulses = pulses + 1;
            time_count = (time_count == 999) ? 0 : time_count + 1;
        end
    endtask
    task begin_case;
        input integer start_count;
        input integer th;
        begin
            @(negedge clk); rst = 1; sample = 0; threshold = th;
            time_count = start_count;
            @(negedge clk); rst = 0;
            pulses = 0;
            repeat (th) tick(0);
        end
    endtask
    task check_tag;
        input integer wanted;
        input integer wanted_pulses;
        begin
            checks = checks + 1;
            if (tag !== wanted || pulses !== wanted_pulses) begin
                errors = errors + 1;
                $display("FAIL check=%0d got tag=%0d pulses=%0d expected tag=%0d pulses=%0d",
                         checks, tag, pulses, wanted, wanted_pulses);
            end else $display("PASS check=%0d tag=%0d pulses=%0d", checks, tag, pulses);
        end
    endtask
    initial begin
        // Clean edge: 4 low to arm, then 4 high to publish.
        begin_case(100, 4);
        first_high = time_count;
        repeat (4) tick(1);
        check_tag(first_high, 1);
        repeat (5) tick(1);
        check_tag(first_high, 1);

        // Multiple reversals: BVM adds one count for each later zero.
        begin_case(300, 4);
        first_high = time_count;
        tick(1); tick(0); tick(1); tick(0); tick(0);
        repeat (4) tick(1);
        expected = (first_high + 3) % 1000;
        check_tag(expected, 1);

        // MOD-1000 correction, not binary MOD-1024.
        begin_case(995, 4);
        first_high = time_count;
        tick(1); tick(0); tick(0); tick(0);
        repeat (4) tick(1);
        check_tag((first_high + 3) % 1000, 1);

        // Threshold 1, and threshold zero alias to 1.
        begin_case(600, 1);
        first_high = time_count;
        tick(1);
        check_tag(first_high, 1);
        begin_case(700, 0);
        tick(0);
        first_high = time_count;
        tick(1);
        check_tag(first_high, 1);

        // High streak shorter than threshold must not publish.
        begin_case(800, 4);
        first_high = time_count;
        repeat (3) tick(1);
        check_tag(0, 0);
        tick(0);
        repeat (4) tick(1);
        check_tag((first_high + 1) % 1000, 1);

        $display("BVM SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors != 0) $fatal(1, "BVM FAILED");
        $display("PASS: BVM unit tests");
        $finish;
    end
    initial begin #100000; $fatal(1, "BVM timeout"); end
endmodule
