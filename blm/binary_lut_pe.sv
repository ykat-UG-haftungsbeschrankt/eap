module binary_lut_pe #(
    parameter int PE_ID = 0,
    parameter int N = 16
) (
    input  logic clk,
    input  logic rst,
    input  logic learning_enable,
    input  logic event_valid,
    input  logic [$clog2(N)-1:0] event_source,
    input  logic teacher_spike,
    input  logic maintenance_tick,
    output logic spike,
    output logic [1:0] membrane_state,
    output logic [N-1:0] synapse_mask
);
    localparam int ID_W = $clog2(N);
    localparam logic [N-1:0] SELF_MASK = N'(1) << PE_ID;
    localparam logic [N-1:0] NONSELF_MASK = ~SELF_MASK;
    localparam int ID_EXT_W = ID_W + 1;
    localparam logic [ID_EXT_W-1:0] N_EXT = ID_EXT_W'(N);

    logic [N-1:0] synapse_on;
    logic [N-1:0] synapse_next;
    logic [N-1:0] source_match;
    logic [N-1:0] pre_event_mask;
    logic [N-1:0] formation_mask;
    logic [N-1:0] depression_mask;
    logic [N-1:0] candidate_pre;
    logic [N-1:0] candidate_pre_next;
    logic [ID_EXT_W-1:0] event_source_ext;
    logic post_recent;
    logic synaptic_input;
    logic [2:0] membrane_lut_result;
    logic will_spike;

    function automatic logic [2:0] membrane_transition(
        input logic [3:0] address
    );
        case (address)
            4'b0000, 4'b0001: membrane_transition = 3'b000;
            4'b0010, 4'b0011: membrane_transition = 3'b010;
            4'b0100:          membrane_transition = 3'b010;
            4'b0101:          membrane_transition = 3'b000;
            4'b0110, 4'b0111: membrane_transition = 3'b100;
            4'b1000:          membrane_transition = 3'b100;
            4'b1001:          membrane_transition = 3'b010;
            4'b1010, 4'b1011: membrane_transition = 3'b001;
            4'b1100, 4'b1101,
            4'b1110, 4'b1111: membrane_transition = 3'b001;
            default:          membrane_transition = 3'b000;
        endcase
    endfunction

    always @* begin
        source_match = '0;
        event_source_ext = {1'b0, event_source};
        for (int s = 0; s < N; s++)
            source_match[s] =
                event_valid && (event_source == ID_W'(s));

        synaptic_input = 1'b0;
        if (event_valid && event_source_ext < N_EXT)
            synaptic_input = synapse_on[event_source];
        membrane_lut_result = membrane_transition(
            {membrane_state, synaptic_input, maintenance_tick}
        );
        will_spike = teacher_spike || membrane_lut_result[0];
        pre_event_mask = source_match & NONSELF_MASK;
        formation_mask =
            {N{will_spike}} & candidate_pre & NONSELF_MASK;
        depression_mask =
            {N{post_recent}} & pre_event_mask;
        synapse_next = (synapse_on & ~depression_mask) | formation_mask;
        candidate_pre_next =
            (candidate_pre & {N{!maintenance_tick}}) | pre_event_mask;
    end

    assign synapse_mask = synapse_on;

    always_ff @(posedge clk) begin
        if (rst) begin
            membrane_state <= 2'b00;
            spike <= 1'b0;
            synapse_on <= '0;
            post_recent <= 1'b0;
            candidate_pre <= '0;
        end else begin
            spike <= will_spike;
            if (will_spike)
                membrane_state <= 2'b00;
            else
                membrane_state <= membrane_lut_result[2:1];

            if (learning_enable) begin
                synapse_on <= synapse_next;
                candidate_pre <= candidate_pre_next;

                if (will_spike)
                    post_recent <= 1'b1;
                else if (maintenance_tick)
                    post_recent <= 1'b0;
            end
        end
    end
endmodule
