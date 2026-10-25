`timescale 1ns/1ps
// Sprint 6B: passive UART frame decoder and expected-phase scoreboard.
// Clocked at 10 MHz, UART divisor 87. This checker assumes no pending-slot
// overwrites in the nominal static integration run; overload is a later test.
module ddmtd_uart_checker #(parameter integer CASE_ID=0,
                            parameter integer CLKS_PER_BIT=87)(
    input wire clk, rst,
    input wire [9:0] avg_phase,
    input wire avg_valid,
    input wire tx
);
    localparam integer BIT_NS = CLKS_PER_BIT * 100;
    integer file_handle, expected_wr, decoded_count, errors;
    integer expected[0:1023];
    integer frame_index, bit_index, frame_start_ps, stop_ps;
    integer first_byte, decoded_byte, word_value;
    reg [63:0] byte_start_ps;
    reg [1023:0] logdir, filename;
    reg [7:0] data_byte;
    reg start_ok, stop_ok;
    initial begin
        expected_wr=0; decoded_count=0; errors=0;
        frame_index=0; first_byte=0;
        if (!$value$plusargs("LOGDIR=%s", logdir)) logdir="results/tb_ddmtd";
        $sformat(filename,"%0s/uart_%0d.csv",logdir,CASE_ID);
        file_handle=$fopen(filename,"w");
        if (!file_handle) $fatal(1,"UART checker cannot open %0s",filename);
        $fdisplay(file_handle,"time_ps,case_id,event,frame_index,byte_value,phase_value,expected_phase,start_ok,stop_ok,match");
    end
    // Record published averages independently of serial line observations.
    always @(posedge clk) begin
        #1;
        if (!rst && avg_valid) begin
            if (expected_wr >= 1024) $fatal(1,"UART checker expected queue overflow");
            expected[expected_wr]=avg_phase;
            expected_wr=expected_wr+1;
        end
    end
    // Decode at bit centers. The first falling edge is the start bit.
    // Wait until after the stop-bit midpoint before looking for another start.
    initial begin
        wait(rst === 1'b0);
        forever begin
            @(negedge tx);
            byte_start_ps = $time * 64'd1000;
            #(BIT_NS/2);
            start_ok=(tx === 1'b0);
            data_byte=0;
            for (bit_index=0; bit_index<8; bit_index=bit_index+1) begin
                #(BIT_NS);
                data_byte[bit_index]=tx;
            end
            #(BIT_NS);
            stop_ok=(tx === 1'b1);
            decoded_byte=data_byte;
            $fdisplay(file_handle,"%0d,%0d,byte,%0d,%0d,-1,-1,%0d,%0d,-1",
                      byte_start_ps,CASE_ID,frame_index,decoded_byte,start_ok,stop_ok);
            if (!start_ok || !stop_ok) begin
                errors=errors+1;
                $fatal(1,"UART framing failure case=%0d frame=%0d",CASE_ID,frame_index);
            end
            if (frame_index == 0) begin
                first_byte=decoded_byte;
                frame_index=1;
            end else begin
                if ((decoded_byte & 8'hfc) != 0) begin
                    errors=errors+1;
                    $fatal(1,"UART high-byte reserved bits nonzero case=%0d",CASE_ID);
                end
                word_value=first_byte | ((decoded_byte & 3)<<8);
                if (decoded_count >= expected_wr) begin
                    errors=errors+1;
                    $fatal(1,"Unexpected UART word case=%0d value=%0d",CASE_ID,word_value);
                end
                $fdisplay(file_handle,"%0d,%0d,word,1,%0d,%0d,%0d,%0d,%0d,%0d",
                          byte_start_ps,CASE_ID,decoded_byte,word_value,expected[decoded_count],
                          start_ok,stop_ok,(word_value == expected[decoded_count]));
                if (word_value !== expected[decoded_count]) begin
                    errors=errors+1;
                    $fatal(1,"UART mismatch case=%0d index=%0d got=%0d expected=%0d",
                           CASE_ID,decoded_count,word_value,expected[decoded_count]);
                end
                decoded_count=decoded_count+1;
                frame_index=0;
            end
        end
    end
    task check_complete;
        begin
            if (frame_index != 0 || decoded_count != expected_wr || errors != 0)
                $fatal(1,"UART incomplete case=%0d expected=%0d decoded=%0d partial=%0d errors=%0d",
                       CASE_ID,expected_wr,decoded_count,frame_index,errors);
            $display("UART INTEGRATION PASS case=%0d words=%0d",CASE_ID,decoded_count);
            $fflush(file_handle);
        end
    endtask
endmodule
