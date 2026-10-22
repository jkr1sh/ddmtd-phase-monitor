`timescale 1ns/1ps
module tb_phase_math;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, pair_reinit=0, pair_valid=0;
    reg [9:0] pair_tag_a=0, pair_tag_b=0;
    wire [9:0] avg_phase;
    wire avg_valid;
    ddmtd_phase_math dut(
        .clk(clk),.rst(rst),.pair_reinit(pair_reinit),
        .pair_tag_a(pair_tag_a),.pair_tag_b(pair_tag_b),
        .pair_valid(pair_valid),.avg_phase(avg_phase),.avg_valid(avg_valid));

    integer checks=0, errors=0, outputs=0, samples=0;
    integer anchor, previous, offset, total;
    integer raw, delta, x, wanted, should_valid;
    integer i;

    // Independent integer scoreboard. Division uses explicit floor handling.
    task clear_model;
        begin samples=0; anchor=0; previous=0; offset=0; total=0; end
    endtask
    task check_output;
        input integer valid_expected;
        input integer phase_expected;
        begin
            checks=checks+1;
            if (avg_valid !== valid_expected[0]) begin
                errors=errors+1;
                $display("FAIL valid check=%0d got=%b expected=%0d",checks,avg_valid,valid_expected);
            end else if (valid_expected && avg_phase !== phase_expected[9:0]) begin
                errors=errors+1;
                $display("FAIL phase check=%0d got=%0d expected=%0d",checks,avg_phase,phase_expected);
            end
            if (avg_valid) outputs=outputs+1;
        end
    endtask
    task send_raw;
        input integer z;
        begin
            if (z<0 || z>=1000) $fatal(1,"Bad test input");
            @(negedge clk);
            pair_tag_a=z[9:0]; pair_tag_b=10'd0; pair_valid=1;
            raw=z;
            if (samples==0) begin
                anchor=raw; previous=raw; offset=0; total=raw;
            end else begin
                delta=raw-previous;
                if (delta < -500) delta=delta+1000;
                else if (delta >= 500) delta=delta-1000;
                offset=offset+delta;
                total=total+anchor+offset;
                previous=raw;
            end
            samples=samples+1;
            should_valid=(samples==16);
            wanted=0;
            if (should_valid) begin
                // Mathematical floor division by 16, including negative sums.
                if (total>=0) x=total/16;
                else x=-((-total+15)/16);
                wanted=((x%1000)+1000)%1000;
            end
            @(posedge clk); #1;
            check_output(should_valid,wanted);
            @(negedge clk); pair_valid=0;
            @(posedge clk); #1;
            check_output(0,0);
            if (should_valid) clear_model();
        end
    endtask
    task send_diff;
        input integer a,b;
        integer z;
        begin
            z=((a-b)%1000+1000)%1000;
            // Exercise actual tag subtraction, not just the zero-B shortcut.
            @(negedge clk);
            pair_tag_a=a; pair_tag_b=b; pair_valid=1;
            if (samples==0) begin
                anchor=z; previous=z; offset=0; total=z;
            end else begin
                delta=z-previous;
                if (delta < -500) delta=delta+1000;
                else if (delta >= 500) delta=delta-1000;
                offset=offset+delta;
                total=total+anchor+offset;
                previous=z;
            end
            samples=samples+1;
            should_valid=(samples==16);
            wanted=0;
            if (should_valid) begin
                if (total>=0) x=total/16;
                else x=-((-total+15)/16);
                wanted=((x%1000)+1000)%1000;
            end
            @(posedge clk); #1; check_output(should_valid,wanted);
            @(negedge clk); pair_valid=0;
            @(posedge clk); #1; check_output(0,0);
            if (should_valid) clear_model();
        end
    endtask
    task restart_math;
        begin
            @(negedge clk); pair_reinit=1; pair_valid=0;
            @(posedge clk); #1; check_output(0,0);
            @(negedge clk); pair_reinit=0;
            clear_model();
        end
    endtask
    initial begin
        clear_model();
        repeat(3) @(negedge clk); rst=0;
        // Static phase with arbitrary nonzero B tag.
        for(i=0;i<16;i=i+1) send_diff(17,817); // raw = 200
        $display("PASS constant differential phase");
        // Forward and reverse modulo crossings.
        for(i=0;i<16;i=i+1) send_raw((970+i*7)%1000);
        $display("PASS forward wrap");
        for(i=0;i<16;i=i+1) send_raw((30-i*7+2000)%1000);
        $display("PASS reverse wrap");
        // Negative locally unwrapped trajectory and floor rounding.
        for(i=0;i<16;i=i+1) send_raw((5-i*11+2000)%1000);
        $display("PASS negative local mean");
        // Maximum unambiguous negative increment, 500-count tie convention.
        for(i=0;i<16;i=i+1) send_raw((999-i*500+10000)%1000);
        $display("PASS half-beat tie and wide accumulator");
        // Maximum positive nearest-neighbor increments.
        for(i=0;i<16;i=i+1) send_raw((1+i*499)%1000);
        $display("PASS positive large steps");
        // Interrupted window must be discarded, no stale samples.
        for(i=0;i<7;i=i+1) send_raw(950+i);
        restart_math();
        for(i=0;i<16;i=i+1) send_raw(42);
        $display("PASS reinitialization");
        // Confirm that gaps without valid do not advance window.
        for(i=0;i<8;i=i+1) send_raw(999);
        repeat(20) begin
            @(posedge clk); #1; check_output(0,0);
        end
        for(i=0;i<8;i=i+1) send_raw(999);
        $display("PASS idle gaps");
        $display("PHASE MATH SUMMARY checks=%0d outputs=%0d errors=%0d",checks,outputs,errors);
        if(errors!=0 || outputs!=8) $fatal(1,"Phase math FAILED");
        $display("PASS: phase arithmetic directed tests");
        $finish;
    end
    initial begin #1000000; $fatal(1,"Phase math timeout"); end
endmodule
