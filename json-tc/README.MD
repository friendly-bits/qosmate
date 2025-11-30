# TC rules in JSON format

The included `json-parser.sh` script can parse JSON files complying with the supported format and translate them into shell code for automatic TC structure generation. Resulting shell code relies on certain functions in `qosmate.d/qosmate-lib-tc.sh`.

The parser automatically extracts TC object ID's (`handle` for TC qdisc, `class id` for TC class) and assigns that ID as parent ID to any child objects when generating the shell code.

For an example of such generated shell code, see `qosmate.d/qosmate-lib-hfsc.sh`, function `apply_rules_hfsc()`.

This is intended as a development feature. JSON files and parser are not installed on user devices.

## **JSON basics**

JSON objects are declared as follows:

```
"some_object": {}
```

JSON strings are declared as follows:

```
"some_key": "some_value"
```

JSON arrays are declared as follows:

```
"array_name": [ "value1", "value2", ... ]
```

No two JSON objects or keys at the same hierarchy level should be named with the same string. Nothing will error out if you have two keys which break this rule, e.g.:

```
"key": "value1",
"key": "value2"
```

but all instances of `key` will be effectively ignored, except the last one.

## **General format rules**

- JSON file must encode hierarchical structure with enclosed objects representing child TC objects of enclosing objects, with the exception of FILTERS[_IPV4|_IPV6]
- FILTERS[_IPV4|_IPV6] are attached to the qdisc specified via the `attach_to` key. Their position in the JSON hierarchy represents where the filter redirects traffic **to**.
- All JSON keys must only include alphanumeric characters and underlines (`_`)
- Only supported objects and keys are allowed

## **Supported objects and keys**

Supported JSON **objects** are: `QDISC[_handle]`, `CLASS_[classid]`, `FILTERS[_IPV4|_IPV6]`, `LOGIC_BRANCH[suffix]`.

- `QDISC` JSON objects can be specified with a handle (e.g. `QDISC_1` represents qdisc with handle `1:`) or without a handle (i.e. simply `QDISC`).
- `CLASS` JSON objects must always specify class id, e.g. `CLASS_1_12` represents class with class id `1:12`.
- `FILTERS[_IPV4|_IPV6]` JSON objects are discussed in a dedicated section below.
- `LOGIC_BRANCH` objects are not directly represented as TC objects but rather allow to generate code which conditionally creates (or not) arbitrary segments of TC structure during the runtime. `LOGIC_BRANCH` objects may be specified with or without suffix, e.g. `LOGIC_BRANCH_5` is valid, as well as `LOGIC_BRANCH`. The optional suffix has no effect on processing.

Optional `"comment[suffix]": "some_string"` key-value pairs may be used anywhere. They are translated into shell code comments. Suffix is optional.

The parser implements format validation and will error out when encountering invalid format. The parser employs the `jshn` utility shipped with OpenWrt and relies on it for general JSON parsing and validation.

### **Helpers**

`QDISC` and `CLASS` objects must specify a `helper` either as their first non-comment key, or their second non-comment key if the `requires` key is present. The value of `helper` must be a shortened name of a helper function defined in the shell context. For example, the following JSON structure: 

```
"QDISC_1": {
	"helper": "test"
}
```

will be translated into following shell code:

```
create_qdisc "test" "1:"
```

During shell code execution, `create_qdisc()` will call `create_tc_obj()` which will call the helper function `test_qdisc_helper()`.

Helper functions for `QDISC` and `CLASS` tc objects are implemented in `qosmate-lib-[cake|hfsc-hybrid|htb].sh` library scripts. These scripts are part of the core refactored qosmate code, rather than this 'extra' JSON parser. However because helpers must be specified in the json files for every TC object, the helper functionality is briefly explained in this document.

The purpose of helper functions is to assemble parameters which are later used when issuing the `tc` commands. Such parameters are set via the global variables `$QDISC_PARAMS` and `CLASS_PARAMS`. Each time a `QDISC` or a `CLASS` tc object is prepared, both variables are reset. Then the helper function sets the parameters via the `$QDISC_PARAMS` variable if it's a qdisc helper, or `$CLASS_PARAMS` variable if it's a class helper.

To pass arguments to the helper function, add the arguments to the value:

```
"QDISC_1": {
	"helper": "test arg1 arg2"
}
```

The parser will translate above snippet into the following shell code:

```
create_qdisc "test arg1 arg2" "1:"
```

During shell code execution, `test_qdisc_helper()` will be called with arguments `arg1`, `arg2`.


### **Filters**

Filters may be specified via the following keys:

- `FILTERS`: translates to "create specified filters for both ipv4 and ipv6"
- `FILTERS_IPV4`, `FILTERS_IPV6`: translates to "create specified filters for given IP family"

`FILTERS[_*]` must always be JSON objects and they always must include the `attach_to` string and the `enums` array, e.g.:

```
"FILTERS": { "attach_to": "1:", "enums": [ "CS0" ] },
"FILTERS_IPV6": { "attach_to": "1:", "enums": [ "CS0", "EF" ] }
```

`FILTERS[_*]` may include a `requires[_or|_and]` key to make them conditional, e.g.:

```
"CLASS_1_15": {
	"helper": "htb_tin bulk",
	"FILTERS": {
		"requires_or": [ "direction": "DOWN", "SFO_ENABLED=1" ],
		"attach_to": "1:",
		"enums": [ "CS1" ]
	}
}
```

Above example will be translated into following shell code:

```
create_class "htb_tin bulk" "1:15" "1:1" || return 1
	if [ "$DIR" = "DOWN" ] || [ "$SFO_ENABLED" = "1" ]; then
		for family in ipv4 ipv6; do
			create_filters "1:" "CS1" "1:15" "$family" || return 1
		done
	fi
```

### **Logic**

`QDISC`, `CLASS`, `FILTERS` and `LOGIC_BRANCH` objects may specify a `requires[_or|_and]` key as their first non-comment key. The `requires` key is translated into logic matching corresponding JSON values vs shell variable values, for certain supported shell variables.

- `requires` JSON values must be of type `string`, e.g. `"requires": "direction=DOWN"`. They only match one variable and one value.

  For example, `"requires": "direction=DOWN"` will be translated into

  ```
  case "$DIR" in 'DOWN')
  	[...]
  esac
  ```

- `requires_or` JSON values must be of type `array`

  For example, `"requires_or": [ "direction=DOWN", "SFO_ENABLED=1" ]` will be translated into

  ```
  if [ "$DIR" = "DOWN" ] || [ "$SFO_ENABLED" = "1" ]; then
  	[...]
  fi
  ```

  If all `requires_or` terms match against the same shell variable, e.g. `"requires_or": [ "gameqdisc=drr", "gameqdisc=qfq" ]`, this will be translated as a `case` statement:

  ```
  case "$gameqdisc" in 'drr'|'qfq')
	  [...]
  esac
  ```

- `requires_and` JSON values must be of type `array` as well. They work similarly to `requires_or`, except the `&&` operator is used in resulting logic.

When multiple consecutive JSON objects specify same `requires[_or|_and]` terms, they will be grouped. For example, following JSON snippet:

```
"QDISC_10": {
	"helper": "hfsc_game",

	"CLASS_10_1": {
		"requires_or": [ "gameqdisc=drr", "gameqdisc=qfq" ],
		"helper": "game_drr_qfq 8000",
		"QDISC_11": { "helper": "red" }
	},
	"CLASS_10_2": {
		"requires_or": [ "gameqdisc=drr", "gameqdisc=qfq" ],
		"helper": "game_drr_qfq 4000",
		"QDISC_12": { "helper": "red" }
	}
```

will be translated into:

```
create_qdisc "hfsc_game" "10:" "1:11" &&
	case "$gameqdisc" in 'drr'|'qfq')
		create_class "game_drr_qfq 8000" "10:1" "10:" &&
			create_qdisc "red" "11:" "10:1" &&
		create_class "game_drr_qfq 4000" "10:2" "10:" &&
			create_qdisc "red" "12:" "10:2" || return 1
	esac
```


Currently the only supported shell variables for matching with `requires` are:
- `gameqdisc` (possible values: `drr`, `qfq`, `pfifo`, `bfifo`, `red`, `fq_codel`, `netem`)
- `direction` (possible values: `UP` for egress or `DOWN` for ingress)
- `SFO_ENABLED` (possible values: `1` for "true", `[any_other_value]` for "false")

Implementing support for matching values of additional shell variables is trivial.
