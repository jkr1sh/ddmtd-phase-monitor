`timescale 1ns/1ps
module tb_pairing;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg [9:0] tag_a = 0, tag_b = 0;
    reg tag_a_valid = 0, tag_b_valid = 0;
    wire [9:0] pair_tag_a, pair_tag_b;
    wire pair_valid, pair_error, tracking_locked, pair_reinit;
    integer pulses = 0, reinits = 0, errors = 0, checks = 0;
    ddmtd_pairing dut (
        .clk(clk), .rst(rst), .tag_a(tag_a), .tag_b(tag_b),
        .tag_a_valid(tag_a_valid), .tag_b_valid(tag_b_valid),
        .pair_tag_a(pair_tag_a), .pair_tag_b(pair_tag_b),
        .pair_valid(pair_valid), .pair_error(pair_error),
        .tracking_locked(tracking_locked), .pair_reinit(pair_reinit)
    );
    always @(negedge clk) begin
        if (!rst) begin
            if (pair_valid) pulses = pulses + 1;
            if (pair_reinit) reinits = reinits + 1;
        end
    end
    task step;
        input integer a, b;
        input integer ta, tb;
        begin
            @(negedge clk);
            tag_a_valid = a != 0;
            tag_b_valid = b != 0;
            tag_a = ta;
            tag_b = tb;
            @(posedge clk); #1;
        end
    endtask
    task idle;
        input integer cycles;
        integer j;
        begin
            for (j=0;j<cycles;j=j+1) step(0,0,0,0);
        end
    endtask
    task both;
        input integer ta, tb;
        begin step(1,1,ta,tb); end
    endtask
    task assert_true;
        input integer condition;
        input [255:0] message;
        begin
            checks = checks + 1;
            if (!condition) begin
                errors = errors + 1;
                $display("FAIL %0s at %0t",message,$time);
            end else $display("PASS %0s",message);
        end
    endtask
    task reset_dut;
        begin
            @(negedge clk); rst=1; tag_a_valid=0; tag_b_valid=0;
            repeat (2) @(negedge clk);
            rst=0;
            pulses=0; reinits=0;
        end
    endtask
    initial begin
        reset_dut();
        both(100,800);
        idle(999); both(100,800);
        idle(999); both(100,800);
        idle(1);
        assert_true(!tracking_locked && !pair_error,"acquisition healthy");
        idle(997); both(100,800); // baseline 1000 cycles after third event
        assert_true(tracking_locked && pulses==0,"baseline discarded and locked");
        idle(999); both(101,801);
        assert_true(pair_valid && pair_tag_a==101 && pair_tag_b==801,"simultaneous pair");
        idle(999); step(1,0,102,0);
        idle(699); step(0,1,0,802); // B interval 1700 -> should fault, so cannot use this!
        assert_true(pair_error && !tracking_locked,"late B detected");
        idle(1);
        assert_true(reinits==1,"single recovery pulse");
        // Fresh acquisition after recovery.
        reset_dut();
        both(50,750);
        idle(999); both(50,750);
        idle(999); both(50,750);
        idle(1); idle(997); both(50,750);
        assert_true(tracking_locked,"tracking reacquired");
        idle(999); step(1,0,60,0);
        idle(100); step(0,1,0,760);
        assert_true(pair_valid && pair_tag_a==60 && pair_tag_b==760,"A-first pair");
        idle(898); step(0,1,0,761); // B first next cycle: B period 999
        idle(100); step(1,0,61,0); // A period 1000
        assert_true(pair_valid && pair_tag_a==61 && pair_tag_b==761,"B-first pair");
        // Early A event should cause fault.
        idle(99); step(1,0,62,0);
        assert_true(pair_error && !tracking_locked && !pair_valid,"early event fault");
        $display("PAIRING SUMMARY checks=%0d errors=%0d",checks,errors);
        if (errors != 0) $fatal(1,"Pairing FAILED");
        $display("PASS: pairing directed tests");
        $finish;
    end
    initial begin #300000; $fatal(1,"Pairing timeout"); end
endmodule
