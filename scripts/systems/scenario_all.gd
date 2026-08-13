extends SceneTree
## 全シナリオを1プロセスで通す一括ランナー。
##
## 実行:
##   godot --headless --path . --script scripts/systems/scenario_all.gd
##
## 全件合格なら exit 0、1件でも失敗があれば exit 1。
## どのシナリオが落ちたかを最後にまとめて出す。
##
## ほとんどのシナリオは load().new() で同じプロセス内から駆動する。
## --script で起動された SceneTree だけがアクティブなので、シナリオ側の
## _finish() が呼ぶ quit() はプロセスを終わらせない（4.7.1 で実測確認済み）。
## ただし SceneTree のインスタンスは root Window を抱えるため、使い終わったら
## free() すること（しないと RID リークの ERROR が大量に出る）。
##
## **await を使うシナリオだけは別プロセスで走らせる。** 子の SceneTree では
## フレームループが回らず `await process_frame` から復帰しないため、同じ
## プロセス内で動かすと _init() が途中で止まり、**残りの検査が黙って
## 実行されない**（実測で37件が消えた）。落ちるより気づけないぶん質が悪いので、
## この4本は OS.execute() で個別に起動して結果を取り込む。
## 子ツリーを process() で手動に回す案も試したが、ハングして使えなかった。
##
## 1本がクラッシュや無限ループを起こすと以降が回らない。その場合は
## 個別実行に切り替えて切り分けること:
##   godot --headless --path . --script scripts/systems/scenario_mN.gd

const SCENARIO_DIR: String = "res://scripts/systems"

## 実行するシナリオの本数。新しいシナリオを足したらここも更新する。
## 更新を忘れても本数の照合が気づいて失敗させる。
const SCENARIO_COUNT: int = 22

## await を含むシナリオの番号。別プロセスで走らせる（上記の理由）。
## シナリオに await を足したらここへ番号を加えること。
## 追加を忘れても _verify_await_list() が検出する。
## 19 は自身に await を書かないが、main.gd の _append_log() が await を含み
## _bind_session() から必ず呼ばれる。_verify_await_list() はシナリオ自身の
## ソースしか見ないため、この事情は検出できない。外さないこと。
const AWAIT_SCENARIOS: Array[int] = [13, 14, 16, 17, 19]

var _results: Array[Dictionary] = []


func _init() -> void:
	print("=== TollRoad 検証シナリオ 一括実行 ===")
	print("")

	var counted: int = _count_scenarios()
	for index: int in range(1, SCENARIO_COUNT + 1):
		_results.append(_run_one(index))

	_report(counted)


## scripts/systems にある scenario_mN.gd の本数を数える。
## SCENARIO_COUNT との照合に使い、登録漏れを検出する。
func _count_scenarios() -> int:
	var dir: DirAccess = DirAccess.open(SCENARIO_DIR)
	if dir == null:
		return -1
	var found: int = 0
	for file_name: String in dir.get_files():
		# 実行時は .gd、書き出し後は .gd.remap になることがある。
		var base_name: String = file_name.trim_suffix(".remap")
		if base_name.begins_with("scenario_m") and base_name.ends_with(".gd"):
			var digits: String = base_name.trim_prefix("scenario_m").trim_suffix(".gd")
			if digits.is_valid_int():
				found += 1
	return found


## 1本走らせて結果を返す。
## {"name": String, "failures": int, "checks": int, "ok": bool}
func _run_one(index: int) -> Dictionary:
	var file_name: String = "scenario_m%d.gd" % index
	var path: String = "%s/%s" % [SCENARIO_DIR, file_name]
	var result: Dictionary = {
		"name": file_name, "failures": 0, "checks": 0, "ok": false,
	}

	# await を使うシナリオは同じプロセスでは最後まで走らない。
	if index in AWAIT_SCENARIOS:
		return _run_in_subprocess(file_name, result)

	var script: Script = load(path) as Script
	if script == null:
		result["failures"] = 1
		print("--- %s ---" % file_name)
		print("  FAIL 読み込めない")
		return result

	# new() した時点で _init() が走り、検査が全て実行される。
	var scenario: Object = script.new()
	result["failures"] = int(scenario.get("_failures"))
	result["checks"] = int(scenario.get("_checks"))
	result["ok"] = result["failures"] == 0
	scenario.free()
	return result


## 別プロセスで1本走らせ、出力から件数を数える。
## await を含むシナリオ専用（同じプロセスでは復帰しないため）。
func _run_in_subprocess(file_name: String, result: Dictionary) -> Dictionary:
	var output: Array = []
	var exit_code: int = OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ".", "--script",
		"%s/%s" % [SCENARIO_DIR.trim_prefix("res://"), file_name],
	], output, true)

	var text: String = "\n".join(output)
	print(text)

	# 子プロセスは _failures を返せないので、出力の行を数える。
	var failures: int = text.count("  FAIL ")
	var checks: int = text.count("  OK   ") + failures
	# 起動そのものに失敗した場合は FAIL 行が出ない。取りこぼさない。
	if exit_code != 0 and failures == 0:
		failures = 1

	result["failures"] = failures
	result["checks"] = checks
	result["ok"] = failures == 0
	return result


## await を使うシナリオが AWAIT_SCENARIOS に登録されているか確かめる。
## 登録漏れがあると、そのシナリオは同じプロセスで走って途中で止まり、
## 残りの検査が黙って実行されない。落ちるより気づけないので必ず検出する。
func _verify_await_list() -> Array[int]:
	var missing: Array[int] = []
	for index: int in range(1, SCENARIO_COUNT + 1):
		if index in AWAIT_SCENARIOS:
			continue
		var path: String = "%s/scenario_m%d.gd" % [SCENARIO_DIR, index]
		var source: String = ""
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file != null:
			source = file.get_as_text()
			file.close()
		if source.contains("await "):
			missing.append(index)
	return missing


## 結果を表にして出す。落ちたシナリオは最後にもう一度並べる。
func _report(counted: int) -> void:
	var total_failures: int = 0
	var total_checks: int = 0
	var passed: int = 0

	print("")
	print("--- 結果 ---")
	for result: Dictionary in _results:
		total_failures += result["failures"]
		total_checks += result["checks"]
		if result["ok"]:
			passed += 1
			print("  OK   %-18s %d 件" % [result["name"], result["checks"]])
		else:
			print("  FAIL %-18s %d / %d 件" % [
				result["name"], result["failures"], result["checks"]])

	print("")
	print("%d 本中 %d 本合格。検査 %d 件中 %d 件失敗。" % [
		_results.size(), passed, total_checks, total_failures])

	# 本数の照合。シナリオを足して SCENARIO_COUNT を更新し忘れると
	# 新しいシナリオが黙って回らないため、ここで止める。
	var count_ok: bool = counted == SCENARIO_COUNT
	if not count_ok:
		print("")
		print("FAIL: シナリオが %d 本あるが SCENARIO_COUNT は %d。" % [
			counted, SCENARIO_COUNT])
		print("      scenario_all.gd の SCENARIO_COUNT を更新すること。")

	# await の登録漏れは検査が黙って消えるため、本数の照合と同じ重さで止める。
	var missing: Array[int] = _verify_await_list()
	if not missing.is_empty():
		print("")
		print("FAIL: await を使うのに AWAIT_SCENARIOS に無いシナリオがある。")
		for index: int in missing:
			print("      scenario_m%d.gd" % index)
		print("      このままでは検査が途中で止まり、黙って実行されない。")

	if total_failures > 0:
		print("")
		print("落ちたシナリオ:")
		for result: Dictionary in _results:
			if not result["ok"]:
				print("  %s  %d 件" % [result["name"], result["failures"]])
				print("    再実行: godot --headless --path . --script %s/%s" % [
					SCENARIO_DIR.trim_prefix("res://"), result["name"]])

	if total_failures == 0 and count_ok and missing.is_empty():
		quit(0)
	else:
		quit(1)
