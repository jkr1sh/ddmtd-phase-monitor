`timescale 1ns/1ps
module tb_uart;
    reg clk = 0;
    always #50 clk = ~clk; // 10 MHz
    reg rst = 1;
    reg [9:0] phase = 0;
    reg phase_valid = 0;
    wire tx;
    integer checks = 0;
    integer errors = 0;
    integer i;
    reg [7:0] received;

    ddmtd_uart_tx dut (
        .clk(clk), .rst(rst), .phase(phase),
        .phase_valid(phase_valid), .tx(tx)
    );

    task send_phase;
        input [9:0] value;
        begin
            @(negedge clk);
            phase = value;
            phase_valid = 1;
            @(negedge clk);
            phase_valid = 0;
        end
    endtask

    task check_byte;
        input [7:0] expected;
        begin
            // Called at the start bit's falling edge, or at the
            // boundary of the second byte's start bit.
            #4350;
            checks = checks + 1;
            if (tx !== 1'b0) begin
                errors = errors + 1;
                $display("FAIL start bit");
            end
            received = 0;
            for (i = 0; i < 8; i = i + 1) begin
                #8700;
                received[i] = tx;
            end
            #8700;
            checks = checks + 1;
            if (tx !== 1'b1 || received !== expected) begin
                errors = errors + 1;
                $display("FAIL UART byte got=%02h stop=%b expected=%02h", received, tx, expected);
            end else
                $display("PASS UART byte %02h", received);
            #4350; // move to next bit boundary
        end
    endtask

    task receive_word;
        input [9:0] expected;
        begin
            @(negedge tx);
            check_byte(expected[7:0]);
            check_byte({6'b0, expected[9:8]});
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        fork
            begin
                receive_word(10'd750);
                receive_word(10'd999);
                receive_word(10'd17);
            end
            begin
                send_phase(10'd750);
                // While transmitting, replace pending 42 with 999.
                repeat (20) @(negedge clk);
                send_phase(10'd42);
                repeat (20) @(negedge clk);
                send_phase(10'd999);
                // 17 arrives during transmission of 999, so queues next.
                repeat (1850) @(negedge clk);
                send_phase(10'd17);
            end
        join
        repeat (5) @(negedge clk);
        checks = checks + 1;
        if (tx !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL idle level");
        end
        $display("UART SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors != 0) $fatal(1, "UART FAILED");
        $display("PASS: UART directed tests");
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "UART timeout");
    end
endmodule
