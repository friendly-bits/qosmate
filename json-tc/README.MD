# TC rules in JSON format

The included `json-parser.sh` script can parse JSON files complying with the supported format and translate them into shell code for automatic TC structure generation. Resulting shell code relies on certain functions in `qosmate.d/qosmate-tc-lib.sh`.

For an example of such generated shell code, see `qosmate.d/hfsc-qdisc-lib.sh`, function `apply_rules_hfsc()`.

## **Supported format**

The parser assumes that the JSON file encodes hierarchical structure with enclosed objects representing child TC objects of enclosing objects.

### **JSON basics**

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

but the first occurence of `key` will be ignored.

### **General format rules**

- All JSON keys must only include alphanumeric characters and underlines (`_`)
- Only supported objects and keys are allowed

### **Supported objects and keys**

Supported JSON objects must be named either `QDISC[_handle]`, `CLASS_[classid]` or `LOGIC_BRANCH[suffix]`.

- `QDISC` JSON objects can be specified with a handle (e.g. `QDISC_1` represents qdisc with handle `1:`) or without a handle (i.e. simply `QDISC`).
- `CLASS` JSON objects must always specify class id, e.g. `CLASS_1_12` represents class with class id `1:12`.
- `LOGIC_BRANCH` objects are not directly represented as TC objects but rather allow to generate code which conditionally creates (or not) arbitrary segments of TC structure during the runtime. `LOGIC_BRANCH` objects may be specified with or without suffix, e.g. `LOGIC_BRANCH_5` is valid, as well as `LOGIC_BRANCH`. The optional suffix has no effect on processing.

Optional `"COMMENT": "some_string"` key-value pairs may be used anywhere - these are ignored by the parser.

The parser implements format validation and will error out when encountering invalid format. The parser employs the `jshn` utility shipped with OpenWrt and relies on it for general JSON parsing and validation. Note that `jshn` implements only limited JSON format validation and error checking, so make sure to provide a valid and sensible JSON file.

#### **Helpers**

`QDISC` and `CLASS` objects must specify a `helper` either as their first key, or their second key if `requires` is present. The helper must be a shortened name of a helper function defined in the shell context. For example, the following JSON structure: 

```
"QDISC_1": {
	"helper": "test"
}
```

will be translated into following shell code:

```
create_qdisc "test" "1:"
```

During the shell code execution, the helper function `test_qdisc_helper()` will be called.

The purpose of helper functions is to assemble parameters which are later used with the `tc` commands. Such parameters are always set via the global variable `$PARAMS`. Each time a `QDISC` or a `CLASS` object is specified, the `$PARAMS` variable is reset.

To pass arguments to the helper function, add the arguments to the value:

```
"QDISC_1": {
	"helper": "test arg1 arg2"
}
```

#### **Filters**

Filters may be specified via the following keys:

- `FILTERS`: translates to "create specified filters for both ipv4 and ipv6"
- `FILTERS_IPV4`, `FILTERS_IPV6`: translates to "create specified filters for given IP family"

`FILTERS[_*]` must always be JSON arrays, e.g.:

```
"FILTERS": [ "CS0" ],
"FILTERS_IPV6": [ "CS0", "EF" ]
```

#### **Logic**

`QDISC`, `CLASS` and `LOGIC_BRANCH` objects may specify a `requires` key as their first key. The `requires` key is translated as a match of certain supported shell variable values. If the value matches, the JSON object is processed, otherwise it is skipped. For example:

```
"QDISC_1": {
	"requires": "gameqdisc=drr",
	"helper": "test"
}
```

Will be translated into following shell code:

```
case "$gameqdisc" in drr)
	create_qdisc "test" "1:"
esac &&
```

The `requires` key may specify multiple alternative matching values by means of the `|` operator, e.g.: `"requires": "gameqdisc=drr|qfq"`.

Currently the only supported shell variables for matching with `requires` are:
- `gameqdisc` (possible values: `drr`, `qfq`, `pfifo`, `bfifo`, `red`, `fq_codel`, `netem`)
- `direction` (possible values: `UP` for egress or `DOWN` for ingress)

Implementing support for matching values of additional shell variables is trivial.
