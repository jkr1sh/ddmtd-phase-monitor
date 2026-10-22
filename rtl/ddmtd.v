// DDMTD phase monitor - Stage 1: sampling and streaming BVM taggers.
// Verilog-2005, synthesizable. Not yet a complete differential phase monitor.
// SPDX-License-Identifier: CERN-OHL-W-2.0+
// BVM state-machine concept adapted from CERN White Rabbit
// dmtd_with_deglitcher.vhd by Tomasz Wlostowski; see README for attribution.
module ddmtd_bvm_tagger (
    input wire clk,
    input wire rst,
    input wire sample,
    input wire [9:0] time_count,
    input wire [3:0] threshold,
    output reg [9:0] tag,
    output reg tag_valid
);
    localparam [1:0] WAIT_LOW = 2'd0, WAIT_EDGE = 2'd1, GOT_EDGE = 2'd2;
    reg [1:0] state;
    reg [3:0] run_count;
    reg [3:0] active_threshold;
    reg [9:0] candidate;
    wire [3:0] effective_threshold = (threshold == 4'd0) ? 4'd1 : threshold;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= WAIT_LOW;
            run_count <= 4'd0;
            active_threshold <= 4'd1;
            candidate <= 10'd0;
            tag <= 10'd0;
            tag_valid <= 1'b0;
        end else begin
            tag_valid <= 1'b0;
            case (state)
                WAIT_LOW: begin
                    if (sample == 1'b0) begin
                        if (run_count == 4'd0)
                            active_threshold <= effective_threshold;
                        if (run_count + 5'd1 >= {1'b0, active_threshold} && run_count != 4'd0) begin
                            state <= WAIT_EDGE;
                            run_count <= 4'd0;
                        end else if (run_count == 4'd0 && effective_threshold == 4'd1) begin
                            state <= WAIT_EDGE;
                            run_count <= 4'd0;
                        end else if (run_count < 4'd15)
                            run_count <= run_count + 4'd1;
                    end else run_count <= 4'd0;
                end
                WAIT_EDGE: begin
                    if (sample == 1'b1) begin
                        candidate <= time_count;
                        if (active_threshold == 4'd1) begin
                            tag <= time_count;
                            tag_valid <= 1'b1;
                            state <= WAIT_LOW;
                            run_count <= 4'd0;
                        end else begin
                            run_count <= 4'd1;
                            state <= GOT_EDGE;
                        end
                    end
                end
                GOT_EDGE: begin
                    if (sample == 1'b0) begin
                        candidate <= (candidate == 10'd999) ? 10'd0 : candidate + 10'd1;
                        run_count <= 4'd0;
                    end else if (run_count + 5'd1 >= {1'b0, active_threshold}) begin
                        tag <= candidate;
                        tag_valid <= 1'b1;
                        run_count <= 4'd0;
                        state <= WAIT_LOW;
                    end else begin
                        run_count <= run_count + 4'd1;
                    end
                end
                default: begin
                    state <= WAIT_LOW;
                    run_count <= 4'd0;
                end
            endcase
        end
    end
endmodule

module ddmtd_stage1 (
    input wire clk,
    input wire rst,
    input wire clk_a,
    input wire clk_b,
    input wire [3:0] bvm_threshold,
    output wire [9:0] tag_a,
    output wire [9:0] tag_b,
    output wire tag_a_valid,
    output wire tag_b_valid
);
    reg [9:0] free_cntr;
    (* ASYNC_REG = "TRUE" *) reg [2:0] sync_a;
    (* ASYNC_REG = "TRUE" *) reg [2:0] sync_b;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            free_cntr <= 10'd0;
            sync_a <= 3'b000;
            sync_b <= 3'b000;
        end else begin
            free_cntr <= (free_cntr == 10'd999) ? 10'd0 : free_cntr + 10'd1;
            sync_a <= {sync_a[1:0], clk_a};
            sync_b <= {sync_b[1:0], clk_b};
        end
    end
    ddmtd_bvm_tagger u_bvm_a (
        .clk(clk), .rst(rst), .sample(sync_a[2]),
        .time_count(free_cntr), .threshold(bvm_threshold),
        .tag(tag_a), .tag_valid(tag_a_valid)
    );
    ddmtd_bvm_tagger u_bvm_b (
        .clk(clk), .rst(rst), .sample(sync_b[2]),
        .time_count(free_cntr), .threshold(bvm_threshold),
        .tag(tag_b), .tag_valid(tag_b_valid)
    );
endmodule

// Stage 2: sequential pairing, per-channel beat watchdog, and reacquisition.
// Verilog-2005. All inputs and outputs are synchronous to clk.
// A valid strobe is sampled at a rising edge; pair_valid is registered.
module ddmtd_pairing #(
    parameter [10:0] MIN_INTERVAL = 11'd500,
    parameter [10:0] MAX_INTERVAL = 11'd1500
) (
    input wire clk,
    input wire rst,
    input wire [9:0] tag_a,
    input wire [9:0] tag_b,
    input wire tag_a_valid,
    input wire tag_b_valid,
    output reg [9:0] pair_tag_a,
    output reg [9:0] pair_tag_b,
    output reg pair_valid,
    output reg pair_error,
    output reg tracking_locked,
    output reg pair_reinit
);
    localparam [1:0] ACQUIRE = 2'd0, TRACK = 2'd1, RECOVER = 2'd2;
    reg [1:0] state;
    reg [10:0] age_a, age_b;
    reg seen_a, seen_b;
    reg [1:0] good_a, good_b;
    reg [9:0] held_a, held_b;
    reg pending_a, pending_b;
    reg baseline_pending;

    // Age counts elapsed sampling-clock edges since the last tag.
    // A tag at MAX_INTERVAL is accepted; absent tags fault once overdue.
    wire bad_a = seen_a && ((tag_a_valid &&
                      (((age_a + 11'd1) < MIN_INTERVAL) || ((age_a + 11'd1) > MAX_INTERVAL))) ||
                      (!tag_a_valid && (age_a >= MAX_INTERVAL)));
    wire bad_b = seen_b && ((tag_b_valid &&
                      (((age_b + 11'd1) < MIN_INTERVAL) || ((age_b + 11'd1) > MAX_INTERVAL))) ||
                      (!tag_b_valid && (age_b >= MAX_INTERVAL)));
    wire duplicate_a = (state == TRACK) && tag_a_valid && pending_a;
    wire duplicate_b = (state == TRACK) && tag_b_valid && pending_b;
    wire fault = bad_a || bad_b || duplicate_a || duplicate_b;
    wire ready_acquire = (good_a >= 2) && (good_b >= 2);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ACQUIRE;
            age_a <= 0; age_b <= 0;
            seen_a <= 0; seen_b <= 0;
            good_a <= 0; good_b <= 0;
            held_a <= 0; held_b <= 0;
            pending_a <= 0; pending_b <= 0;
            baseline_pending <= 0;
            pair_tag_a <= 0; pair_tag_b <= 0;
            pair_valid <= 0; pair_error <= 0;
            tracking_locked <= 0; pair_reinit <= 0;
        end else begin
            pair_valid <= 0;
            pair_reinit <= 0;
            if (state == RECOVER) begin
                // Recovery clears timing history but preserves sticky error.
                state <= ACQUIRE;
                age_a <= 0; age_b <= 0;
                seen_a <= 0; seen_b <= 0;
                good_a <= 0; good_b <= 0;
                pending_a <= 0; pending_b <= 0;
                baseline_pending <= 0;
                tracking_locked <= 0;
            end else if (fault) begin
                state <= RECOVER;
                pair_error <= 1;
                pair_reinit <= 1;
                tracking_locked <= 0;
                pending_a <= 0; pending_b <= 0;
                baseline_pending <= 0;
            end else begin
                // Inter-tag health measurements are independent of pairing.
                if (tag_a_valid) begin
                    if (seen_a && good_a < 2) good_a <= good_a + 1'b1;
                    seen_a <= 1;
                    age_a <= 0;
                end else if (seen_a && age_a < MAX_INTERVAL)
                    age_a <= age_a + 1'b1;

                if (tag_b_valid) begin
                    if (seen_b && good_b < 2) good_b <= good_b + 1'b1;
                    seen_b <= 1;
                    age_b <= 0;
                end else if (seen_b && age_b < MAX_INTERVAL)
                    age_b <= age_b + 1'b1;

                case (state)
                    ACQUIRE: begin
                        // Qualification is based on registered interval counts.
                        // Flush startup tags, then use one new pair as baseline.
                        if (ready_acquire) begin
                            state <= TRACK;
                            baseline_pending <= 1;
                            pending_a <= 0;
                            pending_b <= 0;
                        end
                    end
                    TRACK: begin
                        if (tag_a_valid) begin
                            held_a <= tag_a;
                            pending_a <= 1;
                        end
                        if (tag_b_valid) begin
                            held_b <= tag_b;
                            pending_b <= 1;
                        end
                        // Includes simultaneous arrivals and either arrival order.
                        if ((pending_a || tag_a_valid) &&
                            (pending_b || tag_b_valid)) begin
                            pair_tag_a <= tag_a_valid ? tag_a : held_a;
                            pair_tag_b <= tag_b_valid ? tag_b : held_b;
                            pending_a <= 0;
                            pending_b <= 0;
                            if (baseline_pending) begin
                                baseline_pending <= 0;
                                tracking_locked <= 1;
                            end else if (tracking_locked) begin
                                pair_valid <= 1;
                            end
                        end
                    end
                    default: state <= RECOVER;
                endcase
            end
        end
    end
endmodule
