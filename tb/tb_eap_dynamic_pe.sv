`timescale 1ns/1ps

module tb_eap_dynamic_pe;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic event_valid = 1'b0;
    logic [3:0] event_source = '0;
    logic teacher_spike = 1'b0;
    logic maintenance_tick = 1'b0;
    logic spike;
    logic [4:0] connection_count;

    always #5 clk = ~clk;

    eap_dynamic_pe #(
        .PE_ID(7),
        .N(16),
        .FANIN(16),
        .THRESHOLD(24'sd100),
        .FORM_THRESHOLD(8'd4),
        .PRUNE_AGE(8'd3),
        .MIN_WEIGHT(8'sd2)
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
        input logic [3:0] source,
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
        if (connection_count !== 5'd0 || dut.membrane !== 24'sd0)
            $fatal(1, "reset did not clear PE state");

        @(negedge clk);
        rst = 1'b0;

        repeat (4) drive_cycle(1'b1, 4'd7, 1'b0, 1'b0);
        drive_cycle(1'b0, 4'd0, 1'b1, 1'b0);
        drive_cycle(1'b0, 4'd0, 1'b0, 1'b0);
        drive_cycle(1'b0, 4'd0, 1'b0, 1'b0);
        if (dut.candidate_pre[7] !== 8'd0 || connection_count !== 5'd0)
            $fatal(1, "PE formed a self-connection");
        $display("PASS: self-connections are excluded");

        repeat (4) begin
            drive_cycle(1'b1, 4'd0, 1'b0, 1'b0);
            drive_cycle(1'b1, 4'd3, 1'b0, 1'b0);
        end
        drive_cycle(1'b0, 4'd0, 1'b1, 1'b0);
        if (spike !== 1'b1 || dut.pending[0] !== 1'b1 ||
            dut.pending[3] !== 1'b1)
            $fatal(1, "post-spike did not queue both eligible sources");

        drive_cycle(1'b0, 4'd0, 1'b0, 1'b0);
        if (connection_count !== 5'd1 || dut.syn_source[0] !== 4'd0 ||
            dut.syn_weight[0] !== 8'sd8 || dut.pending[3] !== 1'b1)
            $fatal(1, "first pending connection was not allocated correctly");
        drive_cycle(1'b0, 4'd0, 1'b0, 1'b0);
        if (connection_count !== 5'd2 || dut.syn_source[1] !== 4'd3)
            $fatal(1, "second pending connection was lost or misallocated");
        $display("PASS: formation, ID zero, and one allocation per cycle");

        drive_cycle(1'b0, 4'd0, 1'b1, 1'b0);
        if (dut.syn_weight[0] !== 8'sd9 || dut.syn_weight[1] !== 8'sd9)
            $fatal(1, "postsynaptic activity did not potentiate active sources");
        drive_cycle(1'b1, 4'd0, 1'b0, 1'b0);
        if (dut.syn_weight[0] !== 8'sd8)
            $fatal(1, "presynaptic activity did not depress after post activity");
        drive_cycle(1'b1, 4'd0, 1'b1, 1'b0);
        if (dut.syn_weight[0] !== 8'sd9)
            $fatal(1, "simultaneous pre/post update did not prioritize potentiation");
        $display("PASS: potentiation, depression, and simultaneous-event priority");

        @(negedge clk);
        dut.syn_weight[0] = 8'sd126;
        drive_cycle(1'b0, 4'd0, 1'b1, 1'b0);
        if (dut.syn_weight[0] !== 8'sd127)
            $fatal(1, "positive weight did not saturate at +127");
        drive_cycle(1'b1, 4'd0, 1'b1, 1'b0);
        if (dut.syn_weight[0] !== 8'sd127)
            $fatal(1, "simultaneous update escaped positive saturation");

        @(negedge clk);
        dut.syn_weight[0] = -8'sd126;
        drive_cycle(1'b1, 4'd0, 1'b0, 1'b0);
        if (dut.syn_weight[0] !== -8'sd127)
            $fatal(1, "negative weight did not saturate at -127");
        drive_cycle(1'b1, 4'd0, 1'b0, 1'b0);
        if (dut.syn_weight[0] !== -8'sd127)
            $fatal(1, "negative weight escaped -127 saturation");
        $display("PASS: signed weight saturation at [-127, +127]");

        @(negedge clk);
        dut.syn_weight[0] = 8'sd1;
        dut.syn_weight[1] = 8'sd1;
        repeat (3) drive_cycle(1'b0, 4'd0, 1'b0, 1'b1);
        drive_cycle(1'b1, 4'd0, 1'b0, 1'b1);
        if (connection_count !== 5'd1 || dut.syn_valid[0] !== 1'b1 ||
            dut.syn_valid[1] !== 1'b0 || dut.syn_idle[0] !== 8'd0)
            $fatal(1, "active event did not refresh its synapse at prune age");
        repeat (4) drive_cycle(1'b0, 4'd0, 1'b0, 1'b1);
        if (connection_count !== 5'd0)
            $fatal(1, "weak idle synapse was not pruned");
        $display("PASS: weak-and-idle pruning and activity refresh");

        @(negedge clk);
        rst = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        if (connection_count !== 5'd0 || dut.candidate_pre[0] !== 8'd0 ||
            dut.post_trace !== 8'd0)
            $fatal(1, "reset did not clear learned state");

        @(negedge clk);
        rst = 1'b0;
        repeat (4) drive_cycle(1'b1, 4'd0, 1'b0, 1'b0);
        drive_cycle(1'b0, 4'd0, 1'b1, 1'b0);
        drive_cycle(1'b0, 4'd0, 1'b0, 1'b0);
        drive_cycle(1'b1, 4'd0, 1'b0, 1'b0);
        if (spike !== 1'b0 || dut.membrane !== 24'sd8)
            $fatal(1, "LIF membrane did not integrate the synaptic current");

        @(negedge clk);
        dut.syn_weight[0] = 8'sd127;
        drive_cycle(1'b1, 4'd0, 1'b0, 1'b0);
        if (spike !== 1'b1 || dut.membrane !== 24'sd0)
            $fatal(1, "LIF threshold crossing did not spike and reset membrane");
        $display("PASS: LIF integration, threshold, and spike reset");

        $display("All eap_dynamic_pe tests passed.");
        $finish;
    end
endmodule
