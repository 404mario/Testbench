#!/bin/bash

# ================= 脚本功能说明 =================
# Run Parallel Test v8
# 功能：并行测试 + 自动重试 + 动态 Specs 配置
# 变更：Specs 文件源路径修改为 spec/ 文件夹
# ===================================================

# 0. 初始化记录文件
FAIL_RECORD_FILE=$(mktemp) # 记录最终失败
WARN_RECORD_FILE=$(mktemp) # 记录锁频后通过 (Warning)

# 1. 获取输入指令
INPUT_CMD=$1
if [ -z "$INPUT_CMD" ]; then
    echo "❌ 错误: 请指定测试工具名称或使用 'all_case'。"
    exit 1
fi
shift

# ================= 参数解析区域 =================
NODES_INPUT=""
PASSTHROUGH_ARGS=""
FOUND_SEP=false

for arg in "$@"; do
    if [ "$arg" == "--" ]; then FOUND_SEP=true; continue; fi
    if [ "$FOUND_SEP" = true ]; then PASSTHROUGH_ARGS="$PASSTHROUGH_ARGS $arg"; else NODES_INPUT="$NODES_INPUT $arg"; fi
done

NODES_INPUT=$(echo $NODES_INPUT | xargs)
PASSTHROUGH_ARGS=$(echo $PASSTHROUGH_ARGS | xargs)

# ================= 节点解析区域 =================
NODE_LIST_FILE="./node"
if [ -z "$NODES_INPUT" ]; then echo "❌ 错误: 请指定至少一个节点，或使用 'all'。"; exit 1; fi
NODES=$NODES_INPUT
if [[ "$NODES_INPUT" == *"all"* ]]; then
    if [ -f "$NODE_LIST_FILE" ]; then
        NODES=$(tr ',' ' ' < "$NODE_LIST_FILE" | tr '\n' ' ' | xargs)
        echo "📋 已从文件 '$NODE_LIST_FILE' 加载节点列表: $NODES"
    else
        echo "⚠️  警告: 未找到节点文件，使用默认列表。"
        NODES="node09 node10 node14 node15"
    fi
fi

# ================= 工具列表 =================
if [ "$INPUT_CMD" == "all_case" ]; then
    TARGET_TOOLS_LIST="bench_gemm all_reduce_perf alltoall_perf stream nvbandwidth"
else
    TARGET_TOOLS_LIST="$INPUT_CMD"
fi

# 【修改点】Specs 文件路径增加 spec/ 前缀
# 使用通配符 spec/*.json 可以自动包含该目录下所有 JSON 文件，或者显式指定如下：
COMMON_FILES="spec/*.json"

# ================= 大循环：遍历所有工具 =================
for TOOL_NAME in $TARGET_TOOLS_LIST; do

    echo ""
    echo "========================================================"
    echo "👉 正在执行工具: $TOOL_NAME"
    echo "========================================================"

    REMOTE_OUTPUT="result.json"
    EXEC_BIN=""
    EXTRA_FILES=""
    declare -a JOB_QUEUE

    case $TOOL_NAME in
        "bench_gemm")
            EXEC_BIN="./bench_gemm"; REMOTE_OUTPUT="gemm_result.json"
            if [ "$INPUT_CMD" == "all_case" ]; then
                JOB_QUEUE=("--dtype=fp64" "--dtype=fp32" "--dtype=tf32" "--dtype=fp16" "--dtype=bf16" "--dtype=fp8_e4m3" "--dtype=fp8_e5m2" "--dtype=int8")
            else JOB_QUEUE=("$PASSTHROUGH_ARGS"); fi ;;
        "all_reduce_perf") EXEC_BIN="./all_reduce_perf"; REMOTE_OUTPUT="nccl_allreduce_result.json"; JOB_QUEUE=("$([ "$INPUT_CMD" == "all_case" ] && echo "" || echo "$PASSTHROUGH_ARGS")"); ;;
        "alltoall_perf") EXEC_BIN="./alltoall_perf"; REMOTE_OUTPUT="nccl_alltoall_result.json"; JOB_QUEUE=("$([ "$INPUT_CMD" == "all_case" ] && echo "" || echo "$PASSTHROUGH_ARGS")"); ;;
        "nvbandwidth") EXEC_BIN="./nvbandwidth"; REMOTE_OUTPUT="nvbandwidth_result.json"; JOB_QUEUE=("$([ "$INPUT_CMD" == "all_case" ] && echo "" || echo "$PASSTHROUGH_ARGS")"); ;;
        "stream") EXEC_BIN="./stream"; REMOTE_OUTPUT="stream_result.json"; JOB_QUEUE=("$([ "$INPUT_CMD" == "all_case" ] && echo "" || echo "$PASSTHROUGH_ARGS")"); ;;
        *) echo "❌ 未知工具: $TOOL_NAME"; continue ;;
    esac

    LOCAL_RESULT_BASE="./result"
    LOCAL_TOOL_DIR="$LOCAL_RESULT_BASE/$TOOL_NAME"
    if [ ! -d "$LOCAL_TOOL_DIR" ]; then mkdir -p "$LOCAL_TOOL_DIR"; fi
    REMOTE_WORK_DIR="/tmp/gpu_test_workspace"

    # ================= 子循环：遍历参数 =================
    for CURRENT_RUN_ARGS in "${JOB_QUEUE[@]}"; do
        echo "📂 结果路径: $LOCAL_TOOL_DIR"
        echo "📦 传输文件: $EXEC_BIN $EXTRA_FILES $COMMON_FILES"
        echo "⚙️  应用参数: ${CURRENT_RUN_ARGS:-"(默认)"}"
        echo "----------------------------------------"

        run_on_node() {
            local NODE=$1
            local LOG_PREFIX="[$NODE][$TOOL_NAME]"
            local IS_LOCAL_NODE=0
            if [[ "$NODE" == "127.0.0.1" || "$NODE" == "localhost" ]]; then
                IS_LOCAL_NODE=1
            fi

            # --- 辅助函数：解析结果 ---
            check_status() {
                local json_file=$1
                if command -v python3 &> /dev/null; then
                    python3 -c "import sys, json
try:
    content = sys.stdin.read().strip()
    if not content: print('EmptyFile')
    else:
        d = json.loads(content)
        if isinstance(d, list):
            all_passed = True
            for item in d:
                status = item.get('status', 'Fail')
                if status != 'Passed' and status != 'Pass': all_passed = False; break
            print('Passed' if all_passed and len(d)>0 else 'Failed')
        elif isinstance(d, dict):
            print(d.get('status') or d.get('result') or d.get('pass') or d.get('passed') or 'Done')
        else: print('UnknownFmt')
except: print('PyError')" < "$json_file" 2>/dev/null
                else
                    echo "Saved (NoPy)"
                fi
            }

            # 1. 上传
            # scp spec/xxx.json 过去后，文件会直接在 REMOTE_WORK_DIR 下（不带 spec 目录）
            if [ "$IS_LOCAL_NODE" -eq 1 ]; then
                rm -rf "$REMOTE_WORK_DIR" && mkdir -p "$REMOTE_WORK_DIR"
                cp $EXEC_BIN $EXTRA_FILES $COMMON_FILES "$REMOTE_WORK_DIR/"
            else
                ssh $NODE "rm -rf $REMOTE_WORK_DIR && mkdir -p $REMOTE_WORK_DIR"
                scp -q $EXEC_BIN $EXTRA_FILES $COMMON_FILES $NODE:$REMOTE_WORK_DIR/
            fi

            # 2. 第一次执行
            echo "$LOG_PREFIX 第一次尝试..."
            if [ "$IS_LOCAL_NODE" -eq 1 ]; then
                (
                    cd "$REMOTE_WORK_DIR" && chmod +x * && \
                    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH && \
                    $EXEC_BIN $CURRENT_RUN_ARGS > ${REMOTE_OUTPUT}.log 2>&1
                )
            else
                ssh $NODE "cd $REMOTE_WORK_DIR && chmod +x * && \
                       export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH && \
                       $EXEC_BIN $CURRENT_RUN_ARGS > ${REMOTE_OUTPUT}.log 2>&1"
            fi

            # 文件名处理
            local FILE_SUFFIX=""
            if [ "$TOOL_NAME" == "bench_gemm" ]; then
                local DTYPE_VAL=$(echo "$CURRENT_RUN_ARGS" | grep -oP '(?<=--dtype=)[^ ]+' || echo "")
                if [ ! -z "$DTYPE_VAL" ]; then FILE_SUFFIX="_${DTYPE_VAL}"; fi
            fi
            local LOCAL_FILENAME="${TOOL_NAME}${FILE_SUFFIX}_${NODE}.json"
            local LOCAL_FULL_PATH="$LOCAL_TOOL_DIR/$LOCAL_FILENAME"

            # 取回第一次结果
            local STATUS_MSG="ConnectFail"
            if [ "$IS_LOCAL_NODE" -eq 1 ]; then
                if cp "$REMOTE_WORK_DIR/$REMOTE_OUTPUT" "$LOCAL_FULL_PATH" 2>/dev/null; then
                    STATUS_MSG=$(check_status "$LOCAL_FULL_PATH")
                fi
            else
                if scp -q $NODE:$REMOTE_WORK_DIR/$REMOTE_OUTPUT "$LOCAL_FULL_PATH"; then
                    STATUS_MSG=$(check_status "$LOCAL_FULL_PATH")
                fi
            fi

            # 3. 结果判定
            if [[ "$STATUS_MSG" == "Passed" || "$STATUS_MSG" == "Pass" || "$STATUS_MSG" == "Done" || "$STATUS_MSG" == "Saved (NoPy)" ]]; then
                echo "✅ $LOG_PREFIX 成功 [$STATUS_MSG]"
            else
                # === 失败处理逻辑 ===
                if [ "$TOOL_NAME" == "bench_gemm" ]; then

                    # --- A. 动态获取锁频频率 (Python on Remote) ---
                    # 注意：Python 脚本查找文件时不需要 'spec/' 前缀，因为 scp 已经把它们展平了
                    if [ "$IS_LOCAL_NODE" -eq 1 ]; then
                        LOCK_CLOCK=$(cd "$REMOTE_WORK_DIR" && python3 -c "
import os, json, subprocess
try:
    cmd = 'nvidia-smi --query-gpu=name --format=csv,noheader'
    gpu_name = subprocess.check_output(cmd, shell=True).decode().strip()

    spec_file = ''
    if 'GB300' in gpu_name: spec_file = 'GB300_specs.json'
    elif 'GB200' in gpu_name: spec_file = 'GB200_specs.json'
    elif 'B300' in gpu_name: spec_file = 'B300_specs.json'
    elif 'B200' in gpu_name: spec_file = 'B200_specs.json'
    elif 'H200' in gpu_name: spec_file = 'H200_specs.json'
    elif 'H100' in gpu_name: spec_file = 'H100_specs.json'
    elif 'H20' in gpu_name: spec_file = 'H20_specs.json'
    elif 'A100' in gpu_name: spec_file = 'A100_specs.json'

    target_clock = 0
    if spec_file and os.path.exists(spec_file):
        with open(spec_file, 'r') as f:
            data = json.load(f)
            target_clock = data.get('lock_clock', 0)
    print(int(target_clock))
except:
    print(0)
")
                    else
                        LOCK_CLOCK=$(ssh $NODE "cd $REMOTE_WORK_DIR && python3 -c \"
import os, json, subprocess
try:
    cmd = 'nvidia-smi --query-gpu=name --format=csv,noheader'
    gpu_name = subprocess.check_output(cmd, shell=True).decode().strip()

    spec_file = ''
    if 'GB300' in gpu_name: spec_file = 'GB300_specs.json'
    elif 'GB200' in gpu_name: spec_file = 'GB200_specs.json'
    elif 'B300' in gpu_name: spec_file = 'B300_specs.json'
    elif 'B200' in gpu_name: spec_file = 'B200_specs.json'
    elif 'H200' in gpu_name: spec_file = 'H200_specs.json'
    elif 'H100' in gpu_name: spec_file = 'H100_specs.json'
    elif 'H20' in gpu_name: spec_file = 'H20_specs.json'
    elif 'A100' in gpu_name: spec_file = 'A100_specs.json'

    target_clock = 0
    if spec_file and os.path.exists(spec_file):
        with open(spec_file, 'r') as f:
            data = json.load(f)
            target_clock = data.get('lock_clock', 0)
    print(int(target_clock))
except:
    print(0)
\"")
                    fi
                    LOCK_CLOCK=$(echo $LOCK_CLOCK | xargs)

                    # --- B. 执行锁频与重测 ---
                    if [ "$LOCK_CLOCK" -gt "0" ]; then
                        echo "⚠️  $LOG_PREFIX [GEMM] 测试失败，检测到 GPU 适配频率 ${LOCK_CLOCK}MHz，尝试锁频重测..."

                        # 1. 锁频
                        if [ "$IS_LOCAL_NODE" -eq 1 ]; then
                            nvidia-smi -lgc ${LOCK_CLOCK},${LOCK_CLOCK} > /dev/null 2>&1
                        else
                            ssh $NODE "nvidia-smi -lgc ${LOCK_CLOCK},${LOCK_CLOCK}" > /dev/null 2>&1
                        fi

                        # 2. 第二次执行
                        if [ "$IS_LOCAL_NODE" -eq 1 ]; then
                            (
                                cd "$REMOTE_WORK_DIR" && \
                                export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH && \
                                $EXEC_BIN $CURRENT_RUN_ARGS > ${REMOTE_OUTPUT}.log 2>&1
                            )
                        else
                            ssh $NODE "cd $REMOTE_WORK_DIR && \
                                   export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH && \
                                   $EXEC_BIN $CURRENT_RUN_ARGS > ${REMOTE_OUTPUT}.log 2>&1"
                        fi

                        # 3. 解锁
                        if [ "$IS_LOCAL_NODE" -eq 1 ]; then
                            nvidia-smi -rgc > /dev/null 2>&1
                        else
                            ssh $NODE "nvidia-smi -rgc" > /dev/null 2>&1
                        fi

                        # 4. 再次取回结果
                        if [ "$IS_LOCAL_NODE" -eq 1 ]; then
                            if cp "$REMOTE_WORK_DIR/$REMOTE_OUTPUT" "$LOCAL_FULL_PATH" 2>/dev/null; then
                                local RETRY_STATUS=$(check_status "$LOCAL_FULL_PATH")
                                if [[ "$RETRY_STATUS" == "Passed" || "$RETRY_STATUS" == "Pass" || "$RETRY_STATUS" == "Done" ]]; then
                                    echo "🔶 $LOG_PREFIX 锁频(${LOCK_CLOCK}MHz)后通过! (标记为 Warning)"
                                    echo "$NODE | $TOOL_NAME | $CURRENT_RUN_ARGS | (Recovered @ ${LOCK_CLOCK}MHz)" >> "$WARN_RECORD_FILE"
                                else
                                    echo "❌ $LOG_PREFIX 锁频后依然失败 ($RETRY_STATUS)"
                                    echo "$NODE | $TOOL_NAME | $CURRENT_RUN_ARGS | (Failed)" >> "$FAIL_RECORD_FILE"
                                fi
                            else
                                echo "❌ $LOG_PREFIX 重测后无法取回结果"
                                echo "$NODE | $TOOL_NAME | $CURRENT_RUN_ARGS | (Crash)" >> "$FAIL_RECORD_FILE"
                            fi
                        else
                            if scp -q $NODE:$REMOTE_WORK_DIR/$REMOTE_OUTPUT "$LOCAL_FULL_PATH"; then
                                local RETRY_STATUS=$(check_status "$LOCAL_FULL_PATH")
                                if [[ "$RETRY_STATUS" == "Passed" || "$RETRY_STATUS" == "Pass" || "$RETRY_STATUS" == "Done" ]]; then
                                    echo "🔶 $LOG_PREFIX 锁频(${LOCK_CLOCK}MHz)后通过! (标记为 Warning)"
                                    echo "$NODE | $TOOL_NAME | $CURRENT_RUN_ARGS | (Recovered @ ${LOCK_CLOCK}MHz)" >> "$WARN_RECORD_FILE"
                                else
                                    echo "❌ $LOG_PREFIX 锁频后依然失败 ($RETRY_STATUS)"
                                    echo "$NODE | $TOOL_NAME | $CURRENT_RUN_ARGS | (Failed)" >> "$FAIL_RECORD_FILE"
                                fi
                            else
                                echo "❌ $LOG_PREFIX 重测后无法取回结果"
                                echo "$NODE | $TOOL_NAME | $CURRENT_RUN_ARGS | (Crash)" >> "$FAIL_RECORD_FILE"
                            fi
                        fi
                    else
                        echo "❌ $LOG_PREFIX 失败 ($STATUS_MSG) [未在specs中找到lock_clock配置，跳过重试]"
                        echo "$NODE | $TOOL_NAME | $CURRENT_RUN_ARGS | (Failed_NoClockCfg)" >> "$FAIL_RECORD_FILE"
                    fi

                else
                    echo "❌ $LOG_PREFIX 失败 ($STATUS_MSG) "
                    echo "$NODE | $TOOL_NAME | $CURRENT_RUN_ARGS | (Failed)" >> "$FAIL_RECORD_FILE"
                fi
            fi
        }

        # --- 并行执行 ---
        PIDS=""
        for NODE in $NODES; do
            ( run_on_node $NODE ) &
            PIDS="$PIDS $!"
        done
        wait $PIDS
        echo "✅ [$TOOL_NAME] 当前参数执行完毕。"
        echo ""
    done
done

echo "----------------------------------------"

# ================= 汇总报告区域 =================
if [ -s "$WARN_RECORD_FILE" ]; then
    echo "🔶 =========================================="
    echo "🔶 警告 (Warning): 以下节点经锁频后通过测试"
    echo "🔶 =========================================="
    echo "📋 详情 (Node | Tool | Args | Note):"
    cat "$WARN_RECORD_FILE" | sort | sed 's/^/   - /'
    echo ""
fi

EXIT_CODE=0
if [ -s "$FAIL_RECORD_FILE" ]; then
    echo "❌ =========================================="
    echo "❌ 失败 (Critical): 以下节点测试彻底失败"
    echo "❌ =========================================="
    echo "📋 详情 (Node | Tool | Args):"
    cat "$FAIL_RECORD_FILE" | sort | sed 's/^/   - /'
    EXIT_CODE=1
else
    if [ ! -s "$WARN_RECORD_FILE" ]; then
        echo "🎉 通过: 所有节点一次性通过！"
    else
        echo "⚠️  完成: 所有测试通过，但部分节点触发了重试 (见上文 Warning)"
    fi
fi

rm "$FAIL_RECORD_FILE" "$WARN_RECORD_FILE"
exit $EXIT_CODE
