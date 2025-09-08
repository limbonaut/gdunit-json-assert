class_name JSONAssert
extends GdUnitAssert
## Make assertions on JSON string content.
##
## There are 4 broad categories of operations: [br]
## - Selectors like at() and with_objects() navigate and transform the current
##   candidate set by selecting new values. [br]
## - Filters like containing() and matching() narrow down the candidate set by
##   applying selection criteria without performing assertions. Filter method
##   names end with -ing to distinguish them from assertion methods. [br]
## - Assertions such as must_*, is_*, and has_* methods evaluate candidates
##   against expectations and fail if conditions are not met. [br]
## - Finalizers like verify(), exactly(n), at_most(n), and at_least(n) execute
##   the evaluation chain and report final results. [br]
## [br]
##
## [b]Important[/b]: A finalizer method must be called to execute the assertion
## chain. Use verify() for basic validation, or exactly(n), at_least(n),
## at_most(n) for count-based assertions. Without a finalizer, no assertions or
## queries are performed and a failure is reported. [br]

# NOTE: This file's name ends with AssertImpl.gd to enable correct calculation of line numbers in gdUnit4.

## Encapsulates work to perform in an evaluation step.
class Step:
	var description: String  # step description
	var run: Callable # func(state: EvaluationState) -> StepResult

	func _init(p_description: String, p_run: Callable) -> void:
		description = p_description
		run = p_run

	static func failed(msg: String = "failed") -> StepResult:
		var res := StepResult.new()
		res.passed = false
		res.message = msg
		return res

	static func passed(msg: String = "passed") -> StepResult:
		var res := StepResult.new()
		res.passed = true
		res.message = msg
		return res


## Holds results of step evaluation.
class StepResult:
	var passed: bool = false
	var message: String


## Holds the result of path resolution to distinguish between null values and not found paths.
class PathResult:
	var found: bool = false
	var value: Variant

	func _init(p_found: bool, p_value: Variant = null) -> void:
		found = p_found
		value = p_value

	static func not_found() -> PathResult:
		return PathResult.new(false)

	static func found_value(p_value: Variant) -> PathResult:
		return PathResult.new(true, p_value)


## Holds evaluation state for assertion engine.
class EvaluationState:
	var candidates: Array  # currently considered items
	var steps: Array[Step] = []  # steps queued for evaluation
	var results: Array[StepResult] # holds step evaluation results

	## Applies queued evaluation steps and returns true if all steps passed.
	func apply_steps() -> bool:
		for step: Step in steps:
			if step.run.is_valid():
				results.append(step.run.call(self))
			else:
				push_error("Step must provide implementation for run()!")
				results.append(Step.failed("step.run missing"))
		var steps_passed := true
		for res in results:
			if not res.passed:
				steps_passed = false
				break
		return steps_passed

	## Returns a detailed breakdown of steps performed.
	func get_step_results_pretty(enable_status := true, depth: int = 0) -> PackedStringArray:
		var lines := PackedStringArray()
		for i in steps.size():
			var step := steps[i]
			var result := results[i]
			lines.append(format_result(step.description, result, depth, enable_status))
		return lines

	func format_result(step_name: String, result: StepResult, depth: int, show_status: bool) -> String:
		var status := "FAIL" if not result.passed and show_status else "    "
		var indent := "  ".repeat(depth)
		return "%s  %s%s -> %s" % [status, indent, step_name, result.message]


## Result of evaluating all branches in an either/or_else chain.
class BranchResults:
	var branch_statuses: Array[bool]
	var chain_passed: bool
	var combined_candidates: Array
	var logs: PackedStringArray

	func _init(statuses: Array[bool], survivors: Array = []):
		branch_statuses = statuses
		chain_passed = statuses.any(func(status): return status)
		combined_candidates = survivors


## Encapsulates branching context and logic for either/or_else chains.
class BranchingContext:
	var branches: Array[JSONAssert] = []
	var parent: JSONAssert

	func _init(parent_scope: JSONAssert):
		parent = parent_scope

	func add_branch(branch: JSONAssert) -> void:
		branches.append(branch)

	func evaluate_branches(original: JSONAssert) -> BranchResults:
		var branch_statuses: Array[bool] = []
		var combined_candidates: Array = []

		# Evaluate all branches and combine candidates from passing branches
		for branch: JSONAssert in branches:
			branch._state.candidates = original._state.candidates.duplicate()
			var steps_passed: bool = branch._state.apply_steps()
			branch_statuses.append(steps_passed)

			# If this branch passed, add its candidates to combined results
			if steps_passed:
				for candidate in branch._state.candidates:
					if not combined_candidates.has(candidate):
						combined_candidates.append(candidate)

		return BranchResults.new(branch_statuses, combined_candidates)

	func format_branch_results(results: BranchResults, original: JSONAssert) -> String:
		var show_statuses: bool = not results.chain_passed
		var logs := PackedStringArray()
		var nesting_depth: int = original._get_nesting_depth()

		for i in branches.size():
			var branch: JSONAssert = branches[i]
			if i == 0:
				# First branch result is handled by the main step
				pass
			elif results.branch_statuses[i]:
				logs.append(original._state.format_result("or_else", Step.passed("passed"), nesting_depth, show_statuses))
			else:
				logs.append(original._state.format_result("or_else", Step.failed("failed"), nesting_depth, show_statuses))

			logs.append_array(branch._state.get_step_results_pretty(show_statuses, nesting_depth + 1))

		var first_status = "passed" if results.branch_statuses[0] else "failed"
		return first_status + "\n  " + "\n  ".join(logs)


## Represents a JSON type.
enum Type {
	NULL,
	BOOL,
	NUMBER,
	STRING,
	ARRAY,
	OBJECT
}

var _description: String
var _state: EvaluationState
var _root_value: Variant
var _base: GdUnitAssertImpl
var _invalid: bool = false
var _finalized: bool = false
var _line: int = 0

# Branching support
var _parent_scope: JSONAssert
var _branch_context_stack: Array[BranchingContext] = []


static func assert_json(json: Variant) -> JSONAssert:
	return JSONAssert.new(json)


## Returns the JSON type of the given Variant.
static func json_type(variant: Variant) -> Type:
	match typeof(variant):
		TYPE_NIL:
			return Type.NULL
		TYPE_BOOL:
			return Type.BOOL
		TYPE_INT:
			return Type.NUMBER
		TYPE_FLOAT:
			return Type.NUMBER
		TYPE_STRING:
			return Type.STRING
		TYPE_ARRAY:
			return Type.ARRAY
		TYPE_DICTIONARY:
			return Type.OBJECT
		_:
			push_error("Unsupported variant type in JSON")
			return Type.NULL


## Returns string representation of the JSON type.
static func json_type_string(type: Type) -> String:
	match type:
		Type.NULL:
			return "null"
		Type.BOOL:
			return "boolean"
		Type.NUMBER:
			return "number"
		Type.STRING:
			return "string"
		Type.ARRAY:
			return "array"
		Type.OBJECT:
			return "object"
		_:
			push_error("Unsupported type in JSON")
			return "unknown"


func _init(json: Variant) -> void:
	_base = GdUnitAssertImpl.new(json)
	GdUnitThreadManager.get_current_context().set_assert(self)
	_line = GdUnitAssertions.get_line_number()

	_state = EvaluationState.new()

	if json is String:
		var parsed_value: Variant = JSON.parse_string(json)
		if parsed_value == null and json.strip_edges() != "null":
			_invalid = true
			_state.candidates = []
			_root_value = null
		else:
			_state.candidates = [parsed_value]
			_root_value = parsed_value
	else:
		_state.candidates = [json]
		_root_value = json


func _notification(event :int) -> void:
	if event == NOTIFICATION_PREDELETE:
		if not _finalized:
			_base.report_error("assert_json() was not finalized", _line)
		if _base != null:
			_base.notification(event)
			_base = null


func _add_step(step: Step) -> void:
	_state.steps.append(step)


## Creates a forked copy of this JSONAssert with parent-child relation tracked.
func _fork() -> JSONAssert:
	var fork := JSONAssert.new(null)
	fork._state.candidates = _state.candidates.duplicate()
	fork._parent_scope = self
	fork._root_value = _root_value
	return fork


func current_value() -> Variant:
	return _base.current_value()


func report_success() -> JSONAssert:
	_base.report_success()
	return self


func report_failure(error: String) -> JSONAssert:
	_base.report_error(error, _line)
	return self


func failure_message() -> String:
	return _base.failure_message()


## Sets description for the assertion.
func describe(test_description: String) -> JSONAssert:
	_description = test_description
	return self


## Selects a component at the specified path from the current candidate set.
## The path uses forward slashes as separators (e.g., "/users/0/name").
## For arrays, use numeric indices to access elements; negative indices access from the end.
## Expects exactly one candidate; fails with zero or multiple.
## If the path is not found, the candidate set becomes empty and the step fails.
func at(path: String) -> JSONAssert:
	var step := Step.new("at " + path, func(state: EvaluationState) -> StepResult:
		var candidates: Array

		# If path starts with "/", use root value; otherwise use current context
		if path.begins_with("/"):
			candidates.append(_root_value)
		else:
			candidates.append_array(state.candidates)

		var num_found: int = 0
		var survivors: Array = []
		for c in candidates:
			var result: PathResult = _resolve_path(c, path)
			if result.found:
				num_found += 1
				survivors.append(result.value)

		if num_found != candidates.size():
			state.candidates.clear()
			return Step.failed("expected %d, but found %d" % [candidates.size(), num_found])

		state.candidates = survivors
		return Step.passed("selected " + str(num_found))
	)
	_add_step(step)
	return self


## Selects all objects from array candidates in the current set.
## Each array candidate is expanded to include all its object elements.
## Non-object elements within arrays are filtered out.
func with_objects() -> JSONAssert:
	var step := Step.new("with_objects", func(state: EvaluationState) -> StepResult:
		if state.candidates.is_empty():
			return Step.failed("no candidates")
		var survivors := []
		for c in state.candidates:
			if c is not Array:
				state.candidates.clear()
				return Step.failed("expected array, but found " + json_type_string(json_type(c)))
			for elem in c:
				if elem is Dictionary:
					survivors.append(elem)
		state.candidates = survivors
		return Step.passed("selected " + str(state.candidates.size()))
	)
	_add_step(step)
	return self


## Filters objects by having a property with the given key and value.
## Non-object candidates are filtered out.
func containing(key: String, value: Variant) -> JSONAssert:
	var step := Step.new("containing %s=\"%s\"" % [key, str(value)], func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == 0:
			return Step.passed("no candidates") # filters don't fail
		state.candidates = state.candidates.filter(func(c):
			return json_type(c) == Type.OBJECT and c.has(key) and _are_equal(c[key], value))
		return Step.passed("kept " + str(state.candidates.size()))
	)
	_add_step(step)
	return self


## Filters objects by having properties that match key-value pairs in criterea.
func matching(criteria: Dictionary) -> JSONAssert:
	var step := Step.new("matching \"%s\"" % str(criteria), func(state: EvaluationState) -> StepResult:
		for key in criteria.keys():
			var value: Variant = criteria[key]
			state.candidates = state.candidates.filter(func(c):
				return json_type(c) == Type.OBJECT and c.has(key) and _are_equal(c[key], value)
			)
		return Step.passed("kept " + str(state.candidates.size()))
	)
	_add_step(step)
	return self


func _is_type(expected_type: Type, step_name: String) -> JSONAssert:
	var step := Step.new(step_name, func(state: EvaluationState) -> StepResult:
		var num_candidates: int = state.candidates.size()
		if num_candidates == 0:
			return Step.failed("expected at least 1 candidate, but got " + str(num_candidates))
		for c in state.candidates:
			var actual_type: Type = json_type(c)
			if expected_type != actual_type:
				return Step.failed("expected " + json_type_string(expected_type) + ", but got " + json_type_string(actual_type))
		return Step.passed()
	)
	_add_step(step)
	return self

## Asserts that the current set contains only candidates with the specified type.
func is_type(expected_type: Type) -> JSONAssert:
	return _is_type(expected_type, "is_type " + json_type_string(expected_type))

## Asserts that the current set contains only nulls.
func is_null() -> JSONAssert: return _is_type(Type.NULL, "is_null")

## Asserts that the current set contains only booleans.
func is_bool() -> JSONAssert: return _is_type(Type.BOOL, "is_bool")

## Asserts that the current set contains only numbers.
func is_number() -> JSONAssert: return _is_type(Type.NUMBER, "is_number")

## Asserts that the current set contains only strings.
func is_string() -> JSONAssert: return _is_type(Type.STRING, "is_string")

## Asserts that the current set contains only arrays.
func is_array() -> JSONAssert: return _is_type(Type.ARRAY, "is_array")

## Asserts that the current set contains only objects.
func is_object() -> JSONAssert: return _is_type(Type.OBJECT, "is_object")


## Asserts that each candidate is of one of the specified types.
## To specify types, use JSONAssert.Type.NUMBER, JSONAssert.Type.ARRAY, etc.
func is_one_of_types(expected_types: Array[Type]) -> JSONAssert:
	var step := Step.new("is_one_of_types", func(state: EvaluationState) -> StepResult:
		var num_candidates: int = state.candidates.size()
		if num_candidates == 0:
			return Step.failed("expected at least 1 candidate, but got " + str(num_candidates))
		for c in state.candidates:
			var actual_type: Type = json_type(c)
			if actual_type not in expected_types:
				var types_pretty: Array = expected_types.map(func(it: Type) -> String: return json_type_string(it))
				return Step.failed("expected one of (%s), but got %s" % [
					", ".join(PackedStringArray(types_pretty)),
					json_type_string(json_type(c))])
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that each candidate is empty.
## Supports arrays, objects, and strings.
func is_empty() -> JSONAssert:
	var step := Step.new("is_empty", func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == 0:
			return Step.failed("no candidates")
		for c in state.candidates:
			if json_type(c) in [Type.ARRAY, Type.OBJECT, Type.STRING]:
				if len(c) != 0:
					return Step.failed("expected empty, but found non-empty")
			else:
				return Step.failed("expected array, dictionary or string, but found " + json_type_string(json_type(c)))
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that each candidate is not empty.
## Supports arrays, objects, and strings.
func is_not_empty() -> JSONAssert:
	var step := Step.new("is_not_empty", func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == 0:
			return Step.failed("no candidates")
		for c in state.candidates:
			if json_type(c) in [Type.ARRAY, Type.OBJECT, Type.STRING]:
				if len(c) == 0:
					return Step.failed("expected non-empty, but found empty")
			else:
				return Step.failed("expected array, object or string, but found " + json_type_string(json_type(c)))
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that each candidate has the expected size.
## Supports arrays, objects, and strings.
func has_size(expected_size: int) -> JSONAssert:
	var step := Step.new("has_size %d" % expected_size, func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == 0:
			return Step.failed("no candidates")
		for c in state.candidates:
			if c is Array or c is Dictionary or c is String:
				if len(c) != expected_size:
					return Step.failed("expected size %d, but got %d" % [expected_size, len(c)])
			else:
				return Step.failed("expected array, object or string, but found " + json_type_string(json_type(c)))
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that each candidate contains the expected element.
## Supports arrays and strings.
func has_element(expected_element: Variant) -> JSONAssert:
	var step := Step.new("must_contain_element %s" % expected_element, func(state: EvaluationState) -> StepResult:
		var num_candidates: int = state.candidates.size()
		if num_candidates == 0:
			return Step.failed("no candidates")
		var num_satisfied: int = 0
		for c in state.candidates:
			var type: Type = json_type(c)
			if type in [Type.ARRAY, Type.STRING]:
				if expected_element in c:
					num_satisfied += 1
			else:
				return Step.failed("expected array or string, but found " + json_type_string(type))
		if num_satisfied == num_candidates:
			return Step.passed()
		else:
			return Step.failed("not found in %d candidates" % [num_candidates - num_satisfied])
	)
	_add_step(step)
	return self


## Asserts that each candidate is equal to the expected value.
func must_be(expected_value: Variant) -> JSONAssert:
	var step: Step = Step.new("must_be " + str(expected_value), func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == 0:
			return Step.failed("no candidates")
		for c in state.candidates:
			if not _are_equal(c, expected_value):
				return Step.failed("expected %s, but got %s" % [str(expected_value), str(c)])
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that each candidate is not equal to the expected value.
func must_not_be(expected_value: Variant) -> JSONAssert:
	var step: Step = Step.new("must_not_be " + str(expected_value), func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == 0:
			return Step.failed("no candidates")
		for c in state.candidates:
			if _are_equal(c, expected_value):
				return Step.failed("expected not %s, but got %s" % [str(expected_value), str(c)])
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that all candidates contain a component at the given path.
## If a specific value is provided, also asserts that the component at the path equals that value.
## The path uses forward slashes as separators (e.g., "/users/0/name").
## For arrays, use numeric indices to access elements; negative indices access from the end.
func must_contain(path: String, specific_value: Variant = null) -> JSONAssert:
	var step_name := "must_contain " + path if specific_value == null \
		else "must_contain %s" % [{path: specific_value}]
	var step := Step.new(step_name, func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == 0:
			return Step.failed("no candidates")
		var num_found: int = 0
		for item in _state.candidates:
			var result: PathResult = _resolve_path(item, path)
			if result.found:
				if specific_value and not _are_equal(specific_value, result.value):
					return Step.failed("expected %s, but found %s" %
						[JSON.stringify(specific_value), JSON.stringify(result.value)])
				num_found += 1
		if num_found != state.candidates.size():
			return Step.failed("expected %d, but found %d" % [state.candidates.size(), num_found])
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that all candidates do not contain a component at the given path.
## If a specific value is provided, asserts that the component at the path either does not exist or does not equal that value.
## The path uses forward slashes as separators (e.g., "/users/0/name").
## For arrays, use numeric indices to access elements; negative indices access from the end.
func must_not_contain(path: String, specific_value: Variant = null) -> JSONAssert:
	var step_name := "must_not_contain " + path if specific_value == null \
		else "must_not_contain %s" % [{path: specific_value}]
	var step := Step.new(step_name, func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == 0:
			return Step.failed("no candidates")
		var num_found: int = 0
		for item in _state.candidates:
			var result: PathResult = _resolve_path(item, path)
			if result.found and (specific_value == null or _are_equal(specific_value, result.value)):
				num_found += 1
		if num_found > 0:
			return Step.failed("expected 0, but found " + str(num_found))
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that each candidate is a string that begins with the given prefix.
func must_begin_with(expected_prefix: String) -> JSONAssert:
	var step := Step.new("must_begin_with \"" + expected_prefix + "\"", func(state: EvaluationState) -> StepResult:
		var num_candidates: int = state.candidates.size()
		if num_candidates == 0:
			return Step.failed("expected at least 1 candidate, but got " + str(num_candidates))
		for c in state.candidates:
			if not json_type(c) == Type.STRING:
				return Step.failed("expected string, but got " + json_type_string(json_type(c)))
			if not c.begins_with(expected_prefix):
				return Step.failed("failed with actual \"" + c + "\"")
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that each candidate is a string that ends with the given prefix.
func must_end_with(expected_suffix: String) -> JSONAssert:
	var step := Step.new("must_end_with \"" + expected_suffix + "\"", func(state: EvaluationState) -> StepResult:
		var num_candidates: int = state.candidates.size()
		if num_candidates == 0:
			return Step.failed("expected at least 1 candidate, but got " + str(num_candidates))
		for c in state.candidates:
			if not json_type(c) == Type.STRING:
				return Step.failed("expected string, but got " + json_type_string(json_type(c)))
			if not c.ends_with(expected_suffix):
				return Step.failed("failed with actual \"" + c + "\"")
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that each candidate satisfies the given predicate.
## Predicate is a function that takes a candidate and returns true if it satisfies the condition; otherwise, false.
func must_satisfy(short_description: String, predicate: Callable) -> JSONAssert:
	var step := Step.new("must_satisfy \"" + short_description + "\"", func(state: EvaluationState) -> StepResult:
		var num_candidates: int = state.candidates.size()
		if num_candidates == 0:
			return Step.failed("expected at least 1 candidate, but got " + str(num_candidates))
		for c in state.candidates:
			if not predicate.call(c):
				return Step.failed("failed to satisfy")
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that each candidate matches the given regular expression.
func must_match_regex(regex: RegEx) -> JSONAssert:
	var step := Step.new("must_match_regex \"" + regex.get_pattern() + "\"", func(state: EvaluationState) -> StepResult:
		var num_candidates: int = state.candidates.size()
		if num_candidates == 0:
			return Step.failed("expected at least 1 candidate, but got " + str(num_candidates))

		if not regex.is_valid():
			return Step.failed("invalid regex")

		for c in state.candidates:
			if json_type(c) != Type.STRING:
				return Step.failed("expected string, but got " + json_type_string(json_type(c)))
			if not regex.search(c):
				return Step.failed("failed to match \"" + str(c) + "\"")
		return Step.passed()
	)
	_add_step(step)
	return self


## Asserts that exactly n candidates are currently selected.
## This is a non-finalizing assertion that can be chained with other operations.
## Use this to verify the count of candidates at any point in the chain without terminating it.
func must_selected(n: int) -> JSONAssert:
	var step := Step.new("must_selected " + str(n), func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == n:
			return Step.passed()
		else:
			return Step.failed("expected %d, but got %d" % [n, state.candidates.size()])
	)
	_add_step(step)
	return self


## Finalizes the call chain without additional assertions.
## This method executes all queued steps and reports success if all pass.
func verify() -> void:
	_finalized = true
	if _invalid:
		return report_failure("invalid JSON string")
	var steps_passed: bool = _state.apply_steps()
	if not steps_passed:
		return report_failure(_failure_message(
			_description if not _description.is_empty() else "One or more steps failed",
			_state.candidates))
	return report_success()


## Finalizes the call chain and asserts that exactly N candidates remain.
## This method executes all queued steps and then validates the final count matches the expected number.
func exactly(n: int) -> void:
	var step := Step.new("exactly " + str(n), func(state: EvaluationState) -> StepResult:
		if state.candidates.size() == n:
			return Step.passed()
		else:
			return Step.failed("expected %d, but got %d" % [n, state.candidates.size()])
	)
	_add_step(step)
	verify()


## Finalizes the call chain and asserts that at least N candidates remain.
## This method executes all queued steps and then validates the final count meets the minimum requirement.
func at_least(n: int) -> void:
	var step := Step.new("at_least " + str(n), func(state: EvaluationState) -> StepResult:
		if state.candidates.size() >= n:
			return Step.passed()
		else:
			return Step.failed("expected at least %d, but got %d" % [n, state.candidates.size()])
	)
	_add_step(step)
	verify()


## Finalizes the call chain and asserts that at most N candidates remain.
## This method executes all queued steps and then validates the final count does not exceed the maximum limit.
func at_most(n: int) -> void:
	var step := Step.new("at_most " + str(n), func(state: EvaluationState) -> StepResult:
		if state.candidates.size() <= n:
			return Step.passed()
		else:
			return Step.failed("expected at most %d, but got %d" % [n, state.candidates.size()])
	)
	_add_step(step)
	verify()


## Starts either-or-else chain for conditional assertions.
## Creates a branching context where at least one branch must pass for the chain to succeed.
## To create the next branch in the chain, call or_else().
## For simple value testing, consider using any_of() instead.
## [br][br]
## Example:
## [codeblock]
##	assert_json('{"user": {"role": "admin"}}') \
##	.either() \
##		.at("user/role") \
## 		.must_be("admin") \
##	.or_else() \
## 		.at("user/status") \
## 		.must_be("active") \
##	.end()
## [/codeblock]
func either() -> JSONAssert:
	var context := BranchingContext.new(self)
	_branch_context_stack.push_back(context)
	var fork: JSONAssert = _fork()
	context.add_branch(fork)
	return fork


## Starts the next branch in an either-or-else chain.
## Must be called after either() or another or_else().
## Chain must be ended with end().
func or_else() -> JSONAssert:
	var original: JSONAssert = _get_original_scope()

	if original._branch_context_stack.is_empty():
		push_error("or_else() called without preceding either(). Use either() first to start a branching chain.")
		_invalid = true
		return self

	var context: BranchingContext = original._branch_context_stack[-1]  # Get current context
	var fork: JSONAssert = original._fork()
	context.add_branch(fork)
	return fork


## Ends the either-or-else chain and returns the original JSONAssert instance.
## Evaluates all branches created by either() and or_else() calls, succeeding if at least one branch passes.
func end() -> JSONAssert:
	var original: JSONAssert = _get_original_scope()

	if original._branch_context_stack.is_empty():
		push_error("end() called without preceding either(). Use either() first to start a branching chain.")
		original._invalid = true
		return original

	var context: BranchingContext = original._branch_context_stack.pop_back()  # Remove current context
	var step: Step = _create_branching_step(original, context)
	original._add_step(step)
	return original


## Creates a Step for the branching evaluation.
func _create_branching_step(original: JSONAssert, context: BranchingContext) -> Step:
	var run_callable := func(_unused_state: EvaluationState) -> StepResult:
		var results: BranchResults = context.evaluate_branches(original)
		var log_message: String = context.format_branch_results(results, original)

		# Update original candidates with combined results from all passing branches
		if results.chain_passed and not results.combined_candidates.is_empty():
			original._state.candidates = results.combined_candidates

		if results.chain_passed:
			return Step.passed(log_message)
		else:
			return Step.failed(log_message)

	return Step.new("either", run_callable)


## Gets the original JSONAssert instance (root of the branching chain).
func _get_original_scope() -> JSONAssert:
	return _parent_scope if _parent_scope else self


## Returns a formatted failure report.
func _failure_message(msg: String, survivors: Array) -> String:
	return """
JSON assertion failed: %s.
Step breakdown:
  %s
Final survivors:
  %s
""" % [msg, "\n  ".join(_state.get_step_results_pretty()), str(survivors)]


## Returns a PathResult indicating whether the path was found and its value.
## The path uses forward slashes as separators (e.g., "/users/0/name").
## For arrays, use numeric indices to access elements; negative indices access from the end.
func _resolve_path(data: Variant, path: String) -> PathResult:
	if path.is_empty() or path == "/":
		return PathResult.found_value(data)
	var parts: PackedStringArray = path.rstrip("/").lstrip("/").split("/")
	var current: Variant = data
	for part: String in parts:
		if part.is_empty():
			continue
		if current is Dictionary and current.has(part):
			current = current[part]
		elif current is Array and part.is_valid_int():
			var idx: int = part.to_int()
			if -current.size() <= idx and idx < current.size():
				current = current[idx]
			else:
				return PathResult.not_found()
		else:
			return PathResult.not_found()
	return PathResult.found_value(current)


## Returns true if two JSON-interpreted values are equal.
func _are_equal(v1: Variant, v2: Variant) -> bool:
	# NOTE: All numbers in JSON content are deserialized as float.
	if json_type(v1) == Type.NUMBER and json_type(v2) == Type.NUMBER and float(v1) == float(v2):
		return true
	elif v1 is Dictionary and v2 is Dictionary:
		if v1.size() != v2.size():
			return false
		for key in v1.keys():
			if not v2.has(key) or not _are_equal(v1[key], v2[key]):
				return false
		return true
	elif v1 is Array and v2 is Array:
		if v1.size() != v2.size():
			return false
		for i in range(v1.size()):
			if not _are_equal(v1[i], v2[i]):
				return false
		return true
	return json_type(v1) == json_type(v2) and v1 == v2


func _get_nesting_depth() -> int:
	var depth: int = -1
	var parent: JSONAssert = self
	while parent:
		parent = parent._parent_scope
		depth += 1
	return depth
