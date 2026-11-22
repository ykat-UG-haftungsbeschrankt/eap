`timescale 1ns/1ps

module tb_eap_parameter_boundaries;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic event_valid = 1'b0;
    logic [0:0] event_source = 1'b0;
    logic teacher_spike = 1'b0;
    logic maintenance_tick = 1'b0;
    logic spike;
    logic [0:0] connection_count;

    always #5 clk = ~clk;

    eap_dynamic_pe #(
        .PE_ID(0),
        .N(2),
        .FANIN(1),
        .FORM_THRESHOLD(8'd1),
        .PRUNE_AGE(8'hff)
    ) dut (
        .clk(clk),
        .rst(rst),
        .event_valid(event_valid),
        .event_source(event_source),
        .teacher_spike(teacher_spike),
        .maintenance_tick(maintenance_tick),
        .debug_slot('0),
        .spike(spike),
        .connection_count(connection_count),
        .debug_valid(),
        .debug_source(),
        .debug_weight(),
        .debug_idle()
    );

    task automatic drive_cycle(
        input logic valid,
        input logic source,
        input logic teacher,
        input logic maintenance
    );
        begin
            @(negedge clk);
            event_valid = valid;
            event_source = source;
            teacher_spike = teacher;
            maintenance_tick = maintenance;
            @(posedge clk);
            #1;
            event_valid = 1'b0;
            teacher_spike = 1'b0;
            maintenance_tick = 1'b0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        #1;
        if (connection_count !== 1'b0)
            $fatal(1, "N=2/FANIN=1 reset boundary failed");

        @(negedge clk);
        rst = 1'b0;

        drive_cycle(1'b1, 1'b0, 1'b0, 1'b0);
        drive_cycle(1'b0, 1'b0, 1'b1, 1'b0);
        drive_cycle(1'b0, 1'b0, 1'b0, 1'b0);
        if (dut.candidate_pre[0] !== 8'd0 || connection_count !== 1'b0)
            $fatal(1, "N=2 boundary did not exclude PE_ID zero as a source");

        drive_cycle(1'b1, 1'b1, 1'b0, 1'b0);
        drive_cycle(1'b0, 1'b0, 1'b1, 1'b0);
        if (dut.pending[1] !== 1'b1)
            $fatal(1, "N=2 boundary did not queue source ID one");
        drive_cycle(1'b0, 1'b0, 1'b0, 1'b0);
        if (connection_count !== 1'b1 || dut.syn_source[0] !== 1'b1)
            $fatal(1, "FANIN=1 boundary did not allocate its sole slot");

        $display("PASS: minimum legal PE parameters N=2, FANIN=1");
        $finish;
    end
endmodule
