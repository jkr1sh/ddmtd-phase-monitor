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
