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
    output logic event_ready,
    output logic [N-1:0] spikes,
    output logic [N*5-1:0] packed_connection_counts
);
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
            .spike(spikes[g]),
            .connection_count(count)
        );

        // The prototype top assumes FANIN=16, so each count is 5 bits.
        assign packed_connection_counts[g*5 +: 5] = 5'(count);
    end
endmodule
