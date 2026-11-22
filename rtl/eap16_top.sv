// EAP-16 integration shell. Open-loop only: spike feedback FIFO/router is TODO.
module eap16_top #(
    parameter int N = 16,
    parameter int FANIN = 16
) (
    input  logic clk,
    input  logic rst,
    input  logic event_valid,
    input  logic [3:0] event_source,
    input  logic [N-1:0] teacher_spike,
    input  logic maintenance_tick,
    input  logic [3:0] debug_pe,
    input  logic [3:0] debug_slot,
    output logic event_ready,
    output logic [N-1:0] spikes,
    output logic [N*5-1:0] packed_connection_counts,
    output logic debug_valid,
    output logic [3:0] debug_source,
    output logic signed [7:0] debug_weight,
    output logic [7:0] debug_idle
);
    localparam int ID_W = $clog2(N);
    logic [N-1:0] debug_valid_by_pe;
    logic [N*ID_W-1:0] debug_source_by_pe;
    logic [N*8-1:0] debug_weight_by_pe;
    logic [N*8-1:0] debug_idle_by_pe;

    assign event_ready = 1'b1;

    for (genvar g = 0; g < N; g++) begin : gen_pe
        logic [$clog2(FANIN+1)-1:0] count;
        eap_dynamic_pe #(
            .PE_ID(g),
            .N(N),
            .FANIN(FANIN)
        ) u_pe (
            .clk(clk),
            .rst(rst),
            .event_valid(event_valid),
            .event_source(event_source),
            .teacher_spike(teacher_spike[g]),
            .maintenance_tick(maintenance_tick),
            .debug_slot(debug_slot),
            .spike(spikes[g]),
            .connection_count(count),
            .debug_valid(debug_valid_by_pe[g]),
            .debug_source(debug_source_by_pe[g*ID_W +: ID_W]),
            .debug_weight(debug_weight_by_pe[g*8 +: 8]),
            .debug_idle(debug_idle_by_pe[g*8 +: 8])
        );

        // The prototype top assumes FANIN=16, so each count is 5 bits.
        assign packed_connection_counts[g*5 +: 5] = 5'(count);
    end

    always_comb begin
        debug_valid = 1'b0;
        debug_source = '0;
        debug_weight = '0;
        debug_idle = '0;
        for (int p = 0; p < N; p++) begin
            if (debug_pe == 4'(p)) begin
                debug_valid = debug_valid_by_pe[p];
                debug_source = 4'(debug_source_by_pe[p*ID_W +: ID_W]);
                debug_weight = $signed(debug_weight_by_pe[p*8 +: 8]);
                debug_idle = debug_idle_by_pe[p*8 +: 8];
            end
        end
    end
endmodule
