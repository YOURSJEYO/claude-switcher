import Foundation

@main
struct CheckStateTests {
    static func main() throws {
        let keys = ["代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区",
                    "IPv6", "DNS", "WebRTC", "保镖", "规则置顶",
                    "客户端语言", "ASN属性", "生态可达性"]
        let good = keys.map { "\($0)=ok" }.joined(separator: "\n")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("check.sh")
        // 模拟慢检查，确认面板展开/手动点击不会并发覆盖后台检查。
        try """
        case "$1" in
        checkdetail)
          echo check >> "\(dir.path)/calls"
          sleep 0.2
          cat <<'RESULT'
        \(good)
        RESULT
          ;;
        status)
          template=TW
          [ ! -f "\(dir.path)/template" ] || template=$(cat "\(dir.path)/template")
          echo "current=A hasA=1 hasB=0 template=$template templateMode=manual"
          ;;
        apply-template)
          sleep 0.2
          if [ "$2" = "US" ]; then echo 'FAIL:用户取消'; exit 1; fi
          echo "$2" > "\(dir.path)/template"
          echo "OK:template=$2"
          ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        let vm = VM(core: script.path, monitoring: false)
        vm.refresh(background: true)
        vm.refreshIfStale()
        vm.refresh()
        let deadline = Date().addingTimeInterval(5)
        while vm.isChecking && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(!vm.isChecking && vm.hasData && vm.phase == .ready)
        precondition(vm.netStatus == .safe && vm.rows.count == 14)
        precondition(vm.rows.allSatisfy { $0.state == .ok })
        precondition(vm.current == "A")
        precondition(vm.currentTemplate == .taiwan && vm.selectedTemplate == .taiwan)
        vm.selectedTemplate = .singapore
        vm.applyStatusOutput("current=A hasB=0 template=TW templateMode=manual")
        precondition(vm.selectedTemplate == .singapore, "后台状态不能覆盖用户尚未应用的选择")
        vm.refreshIfStale()
        precondition(!vm.isChecking, "60秒内展开不应重复检查")
        let calls = try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)
        precondition(calls.split(separator: "\n").count == 1)

        vm.applyCheckOutput(good.replacingOccurrences(of: "ASN属性=ok", with: "ASN属性=warn:测试警告"))
        precondition(vm.phase == .ready && vm.netStatus == .warn)
        vm.applyCheckOutput(good.replacingOccurrences(of: "生态可达性=ok", with: "生态可达性=fail:测试失败"))
        precondition(vm.phase == .failed && vm.netStatus == .danger)
        let incomplete = keys.dropLast().map { "\($0)=ok" }.joined(separator: "\n")
        for invalid in ["", "FAIL:操作超时，请重试", incomplete,
                        incomplete + "\n代理内核=ok",
                        good.replacingOccurrences(of: "DNS=ok", with: "DNS=")] {
            vm.applyCheckOutput(invalid)
            precondition(!vm.hasData && vm.phase == .failed && vm.netStatus == .danger)
            precondition(!vm.rows.contains { $0.state == .pending }, "结束后不能遗留转圈行")
        }
        vm.applyCheckOutput(good)
        precondition(vm.hasData && vm.netStatus == .safe && vm.banner.isEmpty)
        vm.applySelectedTemplate()
        precondition(vm.isApplyingTemplate && vm.isBusy)
        vm.refresh() // 应用期间不能启动新的检查
        precondition(!vm.isChecking)
        var until = Date().addingTimeInterval(5)
        while vm.isBusy && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(vm.currentTemplate == .singapore && vm.templatePinned && !vm.templateError)
        precondition(vm.netStatus == .safe && vm.phase == .ready)
        vm.selectedTemplate = .us
        vm.applySelectedTemplate()
        until = Date().addingTimeInterval(5)
        while vm.isBusy && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(vm.templateError && vm.currentTemplate == .singapore)
        precondition(vm.phase == .failed && vm.netStatus == .danger)
        print("PASS: 后台更新14行、展开缓存、并发防重、警告/失败/超时/缺项与恢复")
        print("PASS: 模板读取、待应用选择保留、应用成功后复检、取消时保留旧模板")
    }
}
