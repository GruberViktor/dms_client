import 'package:calendar_date_picker2/calendar_date_picker2.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

final _chipFmt = DateFormat.yMMMd();

/// Compact date-range filter: a chip that opens an anchored dropdown with a
/// single-month range calendar and the two endpoints as editable fields below.
///
/// Material has no compact range calendar — [showDateRangePicker] is a
/// full-screen dialog and its calendar body is private — so the grid comes from
/// `calendar_date_picker2`. The two fields are the stock
/// [InputDatePickerFormField], which brings localized parsing, the
/// `tt.mm.jjjj`-style hint and the German "Ungültiges Format" /
/// out-of-range messages.
///
/// Changes apply immediately: picking two days, or typing a date and pressing
/// Enter / leaving the field, commits through [onChanged].
class DateRangeDropdown extends StatefulWidget {
  final DateTimeRange? value;
  final ValueChanged<DateTimeRange?> onChanged;
  final DateTime firstDate;
  final DateTime lastDate;

  const DateRangeDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<DateRangeDropdown> createState() => _DateRangeDropdownState();
}

class _DateRangeDropdownState extends State<DateRangeDropdown> {
  final _menu = MenuController();
  final _formKey = GlobalKey<FormState>();

  /// Draft endpoints; [_end] is null while a range is half-picked.
  DateTime? _start;
  DateTime? _end;

  /// Month the calendar shows; retargeted when a date is typed.
  DateTime? _displayedMonth;

  void _loadDraft() {
    setState(() {
      _start = widget.value?.start;
      _end = widget.value?.end;
      _displayedMonth = _start;
    });
  }

  /// Pushes the draft out only once it is a complete range — a half-picked
  /// range must not refetch the list.
  void _commit() {
    if (_start != null && _end != null) {
      widget.onChanged(DateTimeRange(start: _start!, end: _end!));
    }
  }

  void _onCalendarChanged(List<DateTime> dates) {
    setState(() {
      _start = dates.isNotEmpty ? dates[0] : null;
      _end = dates.length > 1 ? dates[1] : null;
    });
    _commit();
  }

  void _setStart(DateTime date) {
    setState(() {
      _start = DateUtils.dateOnly(date);
      _displayedMonth = _start;
      // Typing a start past the current end would make an inverted range.
      if (_end != null && _start!.isAfter(_end!)) _end = null;
    });
    _commit();
  }

  void _setEnd(DateTime date) {
    setState(() {
      _end = DateUtils.dateOnly(date);
      _displayedMonth = _end;
      if (_start != null && _end!.isBefore(_start!)) _start = null;
    });
    _commit();
  }

  void _clear() {
    setState(() {
      _start = null;
      _end = null;
    });
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    return MenuAnchor(
      controller: _menu,
      onOpen: _loadDraft,
      alignmentOffset: const Offset(0, 4),
      style: const MenuStyle(padding: WidgetStatePropertyAll(EdgeInsets.zero)),
      menuChildren: [_buildPanel(context)],
      builder: (context, controller, child) => FilterChip(
        label: Text(value == null
            ? 'Zeitraum'
            : '${_chipFmt.format(value.start)} – ${_chipFmt.format(value.end)}'),
        selected: value != null,
        avatar: value == null ? const Icon(Icons.date_range, size: 18) : null,
        onSelected: (_) =>
            controller.isOpen ? controller.close() : controller.open(),
        onDeleted: value != null ? _clear : null,
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 328,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CalendarDatePicker2(
              config: CalendarDatePicker2Config(
                calendarType: CalendarDatePicker2Type.range,
                firstDate: widget.firstDate,
                lastDate: widget.lastDate,
                // Compact enough to sit in a filter-bar dropdown.
                dayMaxWidth: 36,
                controlsHeight: 40,
                hideMonthPickerDividers: true,
                hideYearPickerDividers: true,
                // Clicking before the start extends backwards instead of
                // restarting the selection.
                rangeBidirectional: true,
                selectedDayHighlightColor: scheme.primary,
                selectedRangeHighlightColor: scheme.secondaryContainer,
                selectedDayTextStyle: TextStyle(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
                selectedRangeDayTextStyle:
                    TextStyle(color: scheme.onSecondaryContainer),
              ),
              value: [
                if (_start != null) _start,
                if (_start != null && _end != null) _end,
              ],
              displayedMonthDate: _displayedMonth,
              onValueChanged: _onCalendarChanged,
            ),
            const Divider(height: 9),
            _buildFields(context),
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton(
                  onPressed: _start == null && _end == null ? null : _clear,
                  child: const Text('Zurücksetzen'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _menu.close,
                  child: const Text('Fertig'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFields(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      // Squeeze the stock fields down to filter-bar scale.
      data: theme.copyWith(
        inputDecorationTheme: const InputDecorationThemeData(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        ),
      ),
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _dateField(
                  label: 'Von',
                  initialDate: _start,
                  onDate: _setStart,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _dateField(
                  label: 'Bis',
                  initialDate: _end,
                  onDate: _setEnd,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [InputDatePickerFormField] only reports on submit, so leaving the field
  /// saves it too — otherwise a typed date is silently dropped on tab-away.
  Widget _dateField({
    required String label,
    required DateTime? initialDate,
    required ValueChanged<DateTime> onDate,
  }) =>
      Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus) _formKey.currentState?.save();
        },
        child: InputDatePickerFormField(
          initialDate: initialDate,
          firstDate: widget.firstDate,
          lastDate: widget.lastDate,
          fieldLabelText: label,
          acceptEmptyDate: true,
          onDateSubmitted: onDate,
          onDateSaved: onDate,
        ),
      );
}
