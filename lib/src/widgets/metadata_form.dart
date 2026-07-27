import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../util/format.dart';

/// Collects the typed values of a generated metadata form.
///
/// Wire formats (spec §3): date → "YYYY-MM-DD" string, integer → int,
/// float → double, monetary → decimal **string** (never a double),
/// bool → bool, text/url → string.
class MetadataFormController {
  final Map<String, Object?> _values = {};
  final Map<String, String> serverErrors = {};

  /// Values for create: only non-empty fields are sent.
  Map<String, dynamic> createPayload() =>
      {for (final e in _values.entries) if (e.value != null) e.key: e.value};

  /// Values for PATCH against [original]: changed keys only; a cleared field
  /// becomes an explicit null (the server clears that key on merge).
  Map<String, dynamic> patchPayload(Map<String, dynamic> original) {
    final patch = <String, dynamic>{};
    _values.forEach((key, value) {
      final had = original.containsKey(key) && original[key] != null;
      if (value == null) {
        if (had) patch[key] = null;
      } else if (!had || original[key] != value) {
        patch[key] = value;
      }
    });
    return patch;
  }
}

/// Generates one form field per [MetadataFieldDef]. Wrap in a [Form] and
/// validate/save through its [FormState]; read results off [controller].
class MetadataFormFields extends StatelessWidget {
  final List<MetadataFieldDef> fields;
  final Map<String, dynamic> initialValues;
  final MetadataFormController controller;

  /// Required fields are enforced on create, not on PATCH (spec §3).
  final bool enforceRequired;

  const MetadataFormFields({
    super.key,
    required this.fields,
    required this.controller,
    this.initialValues = const {},
    this.enforceRequired = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final f in fields)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildField(context, f),
          ),
      ],
    );
  }

  Widget _buildField(BuildContext context, MetadataFieldDef f) {
    final initial = initialValues.containsKey(f.key)
        ? initialValues[f.key]
        : f.defaultValue;
    final serverError = controller.serverErrors[f.key];

    switch (f.fieldType) {
      case FieldType.boolean:
        return _BoolField(
          def: f,
          initial: initial == true,
          controller: controller,
        );
      case FieldType.date:
        return _DateField(
          def: f,
          initial: initial?.toString(),
          controller: controller,
          enforceRequired: enforceRequired,
          serverError: serverError,
        );
      default:
        return _TextMetadataField(
          def: f,
          initial: initial,
          controller: controller,
          enforceRequired: enforceRequired,
          serverError: serverError,
        );
    }
  }
}

class _BoolField extends StatefulWidget {
  final MetadataFieldDef def;
  final bool initial;
  final MetadataFormController controller;

  const _BoolField({
    required this.def,
    required this.initial,
    required this.controller,
  });

  @override
  State<_BoolField> createState() => _BoolFieldState();
}

class _BoolFieldState extends State<_BoolField> {
  late bool _value = widget.initial;

  @override
  void initState() {
    super.initState();
    widget.controller._values[widget.def.key] = _value;
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(widget.def.label),
      value: _value,
      onChanged: (v) {
        setState(() => _value = v);
        widget.controller._values[widget.def.key] = v;
      },
    );
  }
}

class _DateField extends StatefulWidget {
  final MetadataFieldDef def;
  final String? initial;
  final MetadataFormController controller;
  final bool enforceRequired;
  final String? serverError;

  const _DateField({
    required this.def,
    required this.initial,
    required this.controller,
    required this.enforceRequired,
    required this.serverError,
  });

  @override
  State<_DateField> createState() => _DateFieldState();
}

class _DateFieldState extends State<_DateField> {
  String? _iso;

  @override
  void initState() {
    super.initState();
    _iso = widget.initial;
    widget.controller._values[widget.def.key] = _iso;
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _iso != null ? DateTime.tryParse(_iso!) ?? now : now,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) {
      setState(() => _iso = picked.toIso8601String().substring(0, 10));
      widget.controller._values[widget.def.key] = _iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FormField<String>(
      validator: (v) {
        if (widget.serverError != null) return widget.serverError;
        if (widget.enforceRequired && widget.def.required && _iso == null) {
          return 'Pflichtfeld';
        }
        return null;
      },
      builder: (state) => InkWell(
        onTap: _pick,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText:
                widget.def.label + (widget.def.required ? ' *' : ''),
            border: const OutlineInputBorder(),
            errorText: state.errorText,
            suffixIcon: _iso != null
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      setState(() => _iso = null);
                      widget.controller._values[widget.def.key] = null;
                    },
                  )
                : const Icon(Icons.calendar_today_outlined, size: 18),
          ),
          child: Text(_iso != null ? formatDate(_iso) : ' '),
        ),
      ),
    );
  }
}

class _TextMetadataField extends StatefulWidget {
  final MetadataFieldDef def;
  final Object? initial;
  final MetadataFormController controller;
  final bool enforceRequired;
  final String? serverError;

  const _TextMetadataField({
    required this.def,
    required this.initial,
    required this.controller,
    required this.enforceRequired,
    required this.serverError,
  });

  @override
  State<_TextMetadataField> createState() => _TextMetadataFieldState();
}

class _TextMetadataFieldState extends State<_TextMetadataField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial?.toString() ?? '');

  @override
  void initState() {
    super.initState();
    _store(_ctrl.text);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  FieldType get _type => widget.def.fieldType;

  void _store(String raw) {
    final text = raw.trim();
    Object? value;
    if (text.isEmpty) {
      value = null;
    } else {
      value = switch (_type) {
        FieldType.integer => int.tryParse(text) ?? text,
        FieldType.float => double.tryParse(text) ?? text,
        // Monetary stays a normalized decimal *string* on the wire.
        FieldType.monetary => _tryDecimal(text) ?? text,
        _ => text,
      };
    }
    widget.controller._values[widget.def.key] = value;
  }

  static String? _tryDecimal(String text) {
    try {
      return Decimal.parse(text.replaceAll(',', '.')).toString();
    } on FormatException {
      return null;
    }
  }

  String? _validate(String? v) {
    if (widget.serverError != null) return widget.serverError;
    final text = (v ?? '').trim();
    if (text.isEmpty) {
      return (widget.enforceRequired && widget.def.required)
          ? 'Pflichtfeld'
          : null;
    }
    return switch (_type) {
      FieldType.integer =>
        int.tryParse(text) == null ? 'Ganze Zahl erwartet' : null,
      FieldType.float =>
        double.tryParse(text) == null ? 'Zahl erwartet' : null,
      FieldType.monetary =>
        _tryDecimal(text) == null ? 'Betrag erwartet, z. B. 1234,50' : null,
      FieldType.url =>
        Uri.tryParse(text)?.hasScheme != true ? 'URL erwartet' : null,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final isNumeric = _type == FieldType.integer ||
        _type == FieldType.float ||
        _type == FieldType.monetary;
    return TextFormField(
      controller: _ctrl,
      decoration: InputDecoration(
        labelText: widget.def.label + (widget.def.required ? ' *' : ''),
        border: const OutlineInputBorder(),
        prefixIcon: _type == FieldType.monetary
            ? const Icon(Icons.payments_outlined, size: 20)
            : null,
        suffixIcon: _type == FieldType.url
            ? IconButton(
                tooltip: 'Link öffnen',
                icon: const Icon(Icons.open_in_new, size: 18),
                onPressed: () {
                  final uri = Uri.tryParse(_ctrl.text.trim());
                  if (uri != null && uri.hasScheme) {
                    launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              )
            : null,
      ),
      keyboardType: isNumeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : (_type == FieldType.url ? TextInputType.url : null),
      inputFormatters: _type == FieldType.integer
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9-]'))]
          : null,
      validator: _validate,
      onChanged: _store,
    );
  }
}
