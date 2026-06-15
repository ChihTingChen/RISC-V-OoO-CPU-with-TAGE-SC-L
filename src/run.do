# run.do — compile + simulate the OoO + BPU design
# Usage in ModelSim console:  do run.do

if {[file exists work]} { vdel -all }
vlib work

vlog -sv riscv_pkg.sv \
        imem.sv dmem.sv prf.sv rat.sv arat.sv free_list.sv \
        bpu.sv decode.sv alu.sv fetch.sv \
        rename_stage.sv rob.sv rs.sv lsq.sv \
        Top.sv \
        tb_Top.sv

vsim -c work.tb_Top
run -all
quit -f
