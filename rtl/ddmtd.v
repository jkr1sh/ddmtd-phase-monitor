// DDMTD phase monitor - Stages 1-4: BVM sampling, pairing, phase arithmetic, integrated top.
// Verilog-2005, synthesizable. UART pending; phase-monitor datapath integrated.
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

// Stage 3: modular subtraction, window-local nearest-neighbor unwrapping,
// 16-pair signed boxcar average, and normalized MOD-1000 output.
// All inputs are synchronous to clk. No division or remainder operators.
module ddmtd_phase_math (
    input  wire       clk,
    input  wire       rst,
    input  wire       pair_reinit,
    input  wire [9:0] pair_tag_a,
    input  wire [9:0] pair_tag_b,
    input  wire       pair_valid,
    output reg  [9:0] avg_phase,
    output reg        avg_valid
);
    // Input tag difference is always in [-999,+999].
    wire signed [11:0] tag_diff =
        $signed({2'b00, pair_tag_a}) - $signed({2'b00, pair_tag_b});
    wire signed [11:0] raw_signed =
        (tag_diff < 12'sd0) ? tag_diff + 12'sd1000 : tag_diff;
    wire [9:0] raw_phase = raw_signed[9:0];

    reg [9:0] prev_raw;
    // First raw phase of the current 16-pair window.
    reg [9:0] window_base;
    reg [3:0] sample_count;
    // At most 15 steps of magnitude 500: local_offset in [-7500,+7485].
    reg signed [13:0] local_offset;
    // Local sample = first phase [0,999] + offset => [-7500,+8484].
    // A 20-bit sum comfortably covers 16 such samples.
    reg signed [19:0] sum;

    wire signed [11:0] raw_step =
        $signed({2'b00, raw_phase}) - $signed({2'b00, prev_raw});
    wire signed [11:0] step =
        (raw_step < -12'sd500) ? raw_step + 12'sd1000 :
        (raw_step >= 12'sd500) ? raw_step - 12'sd1000 : raw_step;
    wire signed [13:0] extended_step = {{2{step[11]}}, step};
    wire signed [13:0] next_offset = local_offset + extended_step;
    wire signed [14:0] local_sample =
        $signed({5'b00000, window_base}) +
        $signed({next_offset[13], next_offset});
    wire signed [19:0] sample_extended = {{5{local_sample[14]}}, local_sample};
    wire signed [19:0] first_sample = $signed({10'b0, raw_phase});
    wire signed [19:0] next_sum =
        (sample_count == 4'd0) ? first_sample : (sum + sample_extended);
    wire signed [19:0] mean = next_sum >>> 4;

    // Mean lies within [-7500,8499]. Convert magnitude to a positive
    // remainder using a fixed sequence of compare/subtract operations.
    // This avoids inferring a general-purpose signed modulo divider.
    wire mean_negative = mean[19];
    wire [13:0] magnitude = mean_negative ? -mean[13:0] : mean[13:0];
    wire [13:0] r8 = (magnitude >= 14'd8000) ? magnitude - 14'd8000 : magnitude;
    wire [13:0] r4 = (r8 >= 14'd4000) ? r8 - 14'd4000 : r8;
    wire [13:0] r2 = (r4 >= 14'd2000) ? r4 - 14'd2000 : r4;
    wire [13:0] r1 = (r2 >= 14'd1000) ? r2 - 14'd1000 : r2;
    wire [9:0] normalized =
        (mean_negative && (r1 != 14'd0)) ? (10'd1000 - r1[9:0]) : r1[9:0];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            prev_raw <= 10'd0;
            window_base <= 10'd0;
            sample_count <= 4'd0;
            local_offset <= 14'sd0;
            sum <= 20'sd0;
            avg_phase <= 10'd0;
            avg_valid <= 1'b0;
        end else begin
            avg_valid <= 1'b0;
            if (pair_reinit) begin
                prev_raw <= 10'd0;
                window_base <= 10'd0;
                sample_count <= 4'd0;
                local_offset <= 14'sd0;
                sum <= 20'sd0;
            end else if (pair_valid) begin
                prev_raw <= raw_phase;
                if (sample_count == 4'd0)
                    window_base <= raw_phase;
                if (sample_count == 4'd15) begin
                    avg_phase <= normalized;
                    avg_valid <= 1'b1;
                    sample_count <= 4'd0;
                    local_offset <= 14'sd0;
                    sum <= 20'sd0;
                end else begin
                    sample_count <= sample_count + 4'd1;
                    local_offset <= (sample_count == 4'd0) ? 14'sd0 : next_offset;
                    sum <= next_sum;
                end
            end
        end
    end
endmodule

// Stage 5: integrated phase monitor with two-byte UART readout.
// All control and arithmetic runs in the sampling clock domain.
module ddmtd (
    input wire clk,
    input wire rst,
    input wire [13:0] in,
    output wire [13:0] out
);
    wire [9:0] tag_a, tag_b;
    wire tag_a_valid, tag_b_valid;
    wire [9:0] pair_tag_a, pair_tag_b;
    wire pair_valid, pair_error, tracking_locked, pair_reinit;
    wire [9:0] avg_phase;
    wire avg_valid;

    ddmtd_stage1 u_frontend (
        .clk(clk), .rst(rst),
        .clk_a(in[0]), .clk_b(in[1]), .bvm_threshold(in[5:2]),
        .tag_a(tag_a), .tag_b(tag_b),
        .tag_a_valid(tag_a_valid), .tag_b_valid(tag_b_valid)
    );

    ddmtd_pairing u_pairing (
        .clk(clk), .rst(rst),
        .tag_a(tag_a), .tag_b(tag_b),
        .tag_a_valid(tag_a_valid), .tag_b_valid(tag_b_valid),
        .pair_tag_a(pair_tag_a), .pair_tag_b(pair_tag_b),
        .pair_valid(pair_valid), .pair_error(pair_error),
        .tracking_locked(tracking_locked), .pair_reinit(pair_reinit)
    );

    ddmtd_phase_math u_phase_math (
        .clk(clk), .rst(rst), .pair_reinit(pair_reinit),
        .pair_tag_a(pair_tag_a), .pair_tag_b(pair_tag_b),
        .pair_valid(pair_valid), .avg_phase(avg_phase), .avg_valid(avg_valid)
    );

    wire uart_tx;
    ddmtd_uart_tx u_uart (
        .clk(clk), .rst(rst), .phase(avg_phase),
        .phase_valid(avg_valid), .tx(uart_tx)
    );
    assign out = {tracking_locked, pair_error, uart_tx, avg_valid, avg_phase};
endmodule

// Two-byte, 8N1 UART transmitter. Each frame: start, 8 LSB-first data, stop.
// New samples while busy occupy a one-entry latest-value pending slot.
// Repeated busy-time arrivals replace that pending value.
module ddmtd_uart_tx #(
    parameter [7:0] CLKS_PER_BIT = 8'd87
) (
    input wire clk,
    input wire rst,
    input wire [9:0] phase,
    input wire phase_valid,
    output reg tx
);
    reg [19:0] shift_bits;
    reg [7:0] baud_count;
    reg [4:0] bits_left;
    reg busy;
    reg pending_valid;
    reg [9:0] pending_phase;

    function [19:0] encode;
        input [9:0] value;
        begin
            // MSB..LSB: stop2, byte2, start2, stop1, byte1, start1
            encode = {1'b1, 6'b000000, value[9:8], 1'b0,
                      1'b1, value[7:0], 1'b0};
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx <= 1'b1;
            shift_bits <= 20'hfffff;
            baud_count <= 8'd0;
            bits_left <= 5'd0;
            busy <= 1'b0;
            pending_valid <= 1'b0;
            pending_phase <= 10'd0;
        end else begin
            if (busy) begin
                if (phase_valid) begin
                    pending_phase <= phase;
                    pending_valid <= 1'b1;
                end
                if (baud_count == CLKS_PER_BIT - 1'b1) begin
                    baud_count <= 8'd0;
                    if (bits_left == 5'd1) begin
                        busy <= 1'b0;
                        bits_left <= 5'd0;
                        tx <= 1'b1;
                    end else begin
                        shift_bits <= {1'b1, shift_bits[19:1]};
                        tx <= shift_bits[1];
                        bits_left <= bits_left - 1'b1;
                    end
                end else begin
                    baud_count <= baud_count + 1'b1;
                end
            end else if (pending_valid) begin
                // Drain the pending sample; a simultaneous new sample
                // becomes the next pending value rather than being lost.
                shift_bits <= encode(pending_phase);
                tx <= 1'b0;
                busy <= 1'b1;
                bits_left <= 5'd20;
                baud_count <= 8'd0;
                pending_valid <= phase_valid;
                if (phase_valid)
                    pending_phase <= phase;
            end else if (phase_valid) begin
                shift_bits <= encode(phase);
                tx <= 1'b0;
                busy <= 1'b1;
                bits_left <= 5'd20;
                baud_count <= 8'd0;
            end else begin
                tx <= 1'b1;
            end
        end
    end
endmodule
