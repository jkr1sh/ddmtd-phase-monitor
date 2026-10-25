`timescale 1ns/1ps
// Passive event logger for DDMTD integration tests (Sprint 6A).
// One instance per DUT. Times are integer picoseconds.
module ddmtd_monitor #(
    parameter integer CASE_ID = 0
)(
    input wire clk, rst,
    input wire [3:0] threshold,
    input wire [9:0] tag_a, tag_b,
    input wire tag_a_valid, tag_b_valid,
    input wire [9:0] pair_tag_a, pair_tag_b,
    input wire pair_valid, pair_reinit,
    input wire [9:0] avg_phase,
    input wire avg_valid, pair_error, tracking_locked
);
    integer ft, fp, fa, ff;
    integer previous_lock, previous_error;
    integer raw_phase;
    reg [1023:0] logdir;
    reg [1023:0] filename;
    reg [63:0] now_ps;
    initial begin
        if (!$value$plusargs("LOGDIR=%s", logdir)) logdir = "results/tb_ddmtd";
        $sformat(filename, "%0s/tags_%0d.csv", logdir, CASE_ID);
        ft = $fopen(filename, "w");
        $sformat(filename, "%0s/pairs_%0d.csv", logdir, CASE_ID);
        fp = $fopen(filename, "w");
        $sformat(filename, "%0s/averages_%0d.csv", logdir, CASE_ID);
        fa = $fopen(filename, "w");
        $sformat(filename, "%0s/faults_%0d.csv", logdir, CASE_ID);
        ff = $fopen(filename, "w");
        if (!ft || !fp || !fa || !ff) $fatal(1, "Monitor: cannot open CSV files for case %0d", CASE_ID);
        $fdisplay(ft, "time_ps,case_id,channel,tag,threshold");
        $fdisplay(fp, "time_ps,case_id,tag_a,tag_b,raw_phase,tracking_locked");
        $fdisplay(fa, "time_ps,case_id,avg_phase,tracking_locked");
        $fdisplay(ff, "time_ps,case_id,event,tracking_locked,pair_error");
        previous_lock = 0;
        previous_error = 0;
    end
    always @(posedge clk) begin
        #1;
        now_ps = $time * 64'd1000;
        if (!rst) begin
            if (tag_a_valid) $fdisplay(ft, "%0d,%0d,A,%0d,%0d", now_ps, CASE_ID, tag_a, threshold);
            if (tag_b_valid) $fdisplay(ft, "%0d,%0d,B,%0d,%0d", now_ps, CASE_ID, tag_b, threshold);
            if (pair_valid) begin
                raw_phase = (pair_tag_a + 1000 - pair_tag_b) % 1000;
                $fdisplay(fp, "%0d,%0d,%0d,%0d,%0d,%0d", now_ps, CASE_ID, pair_tag_a, pair_tag_b, raw_phase, tracking_locked);
            end
            if (avg_valid) $fdisplay(fa, "%0d,%0d,%0d,%0d", now_ps, CASE_ID, avg_phase, tracking_locked);
            if (pair_reinit) $fdisplay(ff, "%0d,%0d,reinit,%0d,%0d", now_ps, CASE_ID, tracking_locked, pair_error);
            if (tracking_locked != previous_lock)
                $fdisplay(ff, "%0d,%0d,%s,%0d,%0d", now_ps, CASE_ID, tracking_locked ? "lock" : "unlock", tracking_locked, pair_error);
            if (pair_error && !previous_error)
                $fdisplay(ff, "%0d,%0d,error_assert,%0d,%0d", now_ps, CASE_ID, tracking_locked, pair_error);
        end
        previous_lock = tracking_locked;
        previous_error = pair_error;
    end
endmodule
