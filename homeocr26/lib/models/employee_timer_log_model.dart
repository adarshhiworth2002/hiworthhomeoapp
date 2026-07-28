/// One Cash/Credit timer log row (Active Sessions / In Progress).
class EmployeeTimerLog {
  const EmployeeTimerLog({
    this.invoiceNo,
    this.invoiceRef,
    this.invoiceLabel,
    this.allUsersOnBill,
    this.workedBy,
    this.startedBy,
    this.completedBy,
    this.billing,
    this.status,
    this.start,
    this.end,
    this.breaksCount,
    this.breakTime,
    this.workDuration,
  });

  final String? invoiceNo;
  final String? invoiceRef;
  final String? invoiceLabel;
  final String? allUsersOnBill;
  final String? workedBy;
  final String? startedBy;
  final String? completedBy;
  final String? billing;
  final String? status;
  final String? start;
  final String? end;
  final int? breaksCount;
  final String? breakTime;
  final String? workDuration;

  factory EmployeeTimerLog.fromJson(Map<String, dynamic> json) {
    String? pick(List<String> keys) {
      for (final key in keys) {
        final v = json[key];
        if (v == null || v == false) continue;
        final text = v.toString().trim();
        if (text.isEmpty || text == 'false') continue;
        return text;
      }
      return null;
    }

    String? many2oneName(String key) {
      final named = json['${key}_name']?.toString().trim();
      if (named != null && named.isNotEmpty && named != 'false') return named;
      final v = json[key];
      if (v is List && v.length >= 2) {
        final name = v[1]?.toString().trim();
        if (name != null && name.isNotEmpty && name != 'false') return name;
      }
      return null;
    }

    String? firstMany2one(List<String> keys) {
      for (final key in keys) {
        final name = many2oneName(key);
        if (name != null) return name;
      }
      return null;
    }

    String? scan(String needle) {
      final n = needle.toLowerCase();
      for (final entry in json.entries) {
        final key = entry.key.toLowerCase();
        if (!key.contains(n)) continue;
        final named = json['${entry.key}_name'];
        if (named != null && named != false) {
          final text = named.toString().trim();
          if (text.isNotEmpty && text != 'false') return text;
        }
        final v = entry.value;
        if (v == null || v == false) continue;
        if (v is List && v.length >= 2) {
          final name = v[1]?.toString().trim();
          if (name != null && name.isNotEmpty && name != 'false') return name;
          continue;
        }
        final text = v.toString().trim();
        if (text.isEmpty || text == 'false') continue;
        return text;
      }
      return null;
    }

    int? pickInt(List<String> keys) {
      for (final key in keys) {
        final v = json[key];
        if (v is int) return v;
        if (v is num) return v.toInt();
        final parsed = int.tryParse(v?.toString() ?? '');
        if (parsed != null) return parsed;
      }
      return null;
    }

    final workedBy = firstMany2one(const [
          'worked_by',
          'worked_by_id',
          'worker_id',
          'employee_id',
          'user_id',
        ]) ??
        pick(const [
          'worked_by',
          'worked_by_name',
          'worker_name',
          'employee_name',
        ]) ??
        scan('worked') ??
        scan('worker');

    // Website "Started By" — prefer dedicated fields, then create_uid.
    final startedBy = firstMany2one(const [
          'started_by',
          'started_by_id',
          'start_uid',
          'create_uid',
        ]) ??
        pick(const [
          'started_by',
          'started_by_name',
          'start_user',
        ]) ??
        scan('started_by') ??
        workedBy;

    final completedBy = firstMany2one(const [
          'completed_by',
          'completed_by_id',
          'done_by',
        ]) ??
        pick(const ['completed_by', 'completed_by_name']) ??
        scan('completed') ??
        workedBy;

    final allUsers = pick(const [
          'all_users_on_bill',
          'all_users',
          'bill_users',
          'users_on_bill',
        ]) ??
        scan('all_user') ??
        workedBy;

    final rawBilling = pick(const [
          'billing',
          'billing_type',
          'billing_mode',
          'billing_stage',
          'bill_type',
          'invoice_billing',
        ]) ??
        scan('billing');
    final billing = _formatBilling(rawBilling, json);

    final start = pick(const [
          'start',
          'start_time',
          'date_start',
          'started_on',
          'start_datetime',
        ]) ??
        scan('start_time') ??
        scan('date_start');

    final end = pick(const [
      'end',
      'end_time',
      'date_end',
      'ended_on',
      'end_datetime',
    ]);

    final rawDuration = pick(const [
          'work_duration',
          'session_work_duration',
          'worked_duration',
          'duration',
          'timer_duration',
          'total_duration',
          'duration_display',
          'work_time',
          'worked_hours',
          'work_hours',
        ]) ??
        scan('duration') ??
        scan('work_time');

    final workDuration =
        _formatDuration(rawDuration) ?? _durationFromStart(start, end);

    final invoiceNo = pick(const [
          'invoice_no',
          'invoice_number',
          'display_name',
          'name',
        ]) ??
        many2oneName('invoice_id') ??
        many2oneName('move_id') ??
        scan('invoice');

    final invoiceDate = pick(const [
      'invoice_date',
      'date_invoice',
      'bill_date',
    ]);
    final invoiceLabel = pick(const ['invoice_label', 'invoice_display']) ??
        (invoiceNo != null && invoiceDate != null
            ? '$invoiceNo - $invoiceDate'
            : invoiceNo);

    return EmployeeTimerLog(
      invoiceNo: invoiceNo,
      invoiceRef: pick(const ['invoice_ref', 'ref', 'reference']) ?? '/',
      invoiceLabel: invoiceLabel,
      allUsersOnBill: allUsers,
      workedBy: workedBy,
      startedBy: startedBy,
      completedBy: completedBy,
      billing: billing,
      status: pick(const ['status', 'state']) ?? 'Running',
      start: start,
      end: end,
      breaksCount: pickInt(const ['breaks', 'break_count', 'breaks_count']) ?? 0,
      breakTime: _formatDuration(
            pick(const [
              'break_time',
              'total_break_time',
              'break_duration',
              'break_hours',
            ]),
          ) ??
          '00:00',
      workDuration: workDuration,
    );
  }

  /// Fill gaps so website columns always have a readable value.
  EmployeeTimerLog enriched() {
    final by = (workedBy ?? '').trim();
    final started = (startedBy ?? '').trim();
    final completed = (completedBy ?? '').trim();
    final users = (allUsersOnBill ?? '').trim();
    final bill = (billing ?? '').trim();
    final duration = (workDuration ?? '').trim();
    final inv = (invoiceNo ?? '').trim();

    return EmployeeTimerLog(
      invoiceNo: inv.isEmpty ? null : inv,
      invoiceRef: (invoiceRef == null || invoiceRef!.trim().isEmpty)
          ? '/'
          : invoiceRef,
      invoiceLabel: (invoiceLabel == null || invoiceLabel!.trim().isEmpty)
          ? (inv.isEmpty ? null : inv)
          : invoiceLabel,
      allUsersOnBill: users.isNotEmpty ? users : (by.isNotEmpty ? by : null),
      workedBy: by.isEmpty ? null : by,
      startedBy: started.isNotEmpty ? started : (by.isNotEmpty ? by : null),
      completedBy:
          completed.isNotEmpty ? completed : (by.isNotEmpty ? by : null),
      billing: bill.isNotEmpty ? bill : 'Full Billing',
      status: status ?? 'Running',
      start: start,
      end: end,
      breaksCount: breaksCount ?? 0,
      breakTime: (breakTime == null || breakTime!.trim().isEmpty)
          ? '00:00'
          : breakTime,
      workDuration: duration.isNotEmpty
          ? duration
          : (_durationFromStart(start, end) ?? '00:00:00'),
    );
  }

  factory EmployeeTimerLog.fromEmployee({
    required String employeeName,
    String? invoiceNo,
    int activeSessions = 1,
    String? billing,
    String? workDuration,
    String? start,
  }) {
    return EmployeeTimerLog(
      invoiceNo: invoiceNo,
      invoiceRef: '/',
      invoiceLabel: invoiceNo,
      allUsersOnBill: employeeName,
      workedBy: employeeName,
      startedBy: employeeName,
      completedBy: employeeName,
      billing: _formatBilling(billing, const {}) ?? 'Full Billing',
      status: 'Running',
      start: start,
      end: null,
      breaksCount: 0,
      breakTime: '00:00',
      workDuration: _formatDuration(workDuration) ??
          _durationFromStart(start, null) ??
          '00:00:00',
    );
  }

  static String? _formatBilling(String? raw, Map<String, dynamic> json) {
    if (json['full_billing'] == true || json['is_full_billing'] == true) {
      return 'Full Billing';
    }
    if (json['half_billing'] == true || json['is_half_billing'] == true) {
      return 'Half Billing';
    }

    if (raw == null) return null;
    final v = raw.trim().toLowerCase().replaceAll('_', ' ');
    if (v.isEmpty || v == 'false') return null;
    if (v.contains('full')) return 'Full Billing';
    if (v.contains('half')) return 'Half Billing';
    if (v == 'full' || v == '1') return 'Full Billing';
    if (v == 'half' || v == '0') return 'Half Billing';
    if (raw.contains(' ')) return raw.trim();
    return raw.trim();
  }

  static String? _formatDuration(dynamic value) {
    if (value == null || value == false) return null;
    final text = value.toString().trim();
    if (text.isEmpty || text == 'false') return null;
    if (text.contains(':')) return text;

    final n = value is num ? value.toDouble() : double.tryParse(text);
    if (n == null) return text;

    final totalSeconds = n >= 100000 ? n.round() : (n * 3600).round();
    if (totalSeconds < 0) return text;

    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  static String? _durationFromStart(String? start, String? end) {
    final startAt = _parseDateTime(start);
    if (startAt == null) return null;
    final endAt = _parseDateTime(end) ?? DateTime.now();
    final secs = endAt.difference(startAt).inSeconds;
    if (secs < 0) return null;
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  static DateTime? _parseDateTime(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty || text == 'false') return null;

    final iso = DateTime.tryParse(text.replaceFirst(' ', 'T'));
    if (iso != null) return iso;

    final m = RegExp(
      r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?$',
      caseSensitive: false,
    ).firstMatch(text);
    if (m != null) {
      final d = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      final y = int.parse(m.group(3)!);
      var h = int.parse(m.group(4)!);
      final mi = int.parse(m.group(5)!);
      final s = int.parse(m.group(6) ?? '0');
      final ampm = m.group(7)?.toUpperCase();
      if (ampm == 'PM' && h < 12) h += 12;
      if (ampm == 'AM' && h == 12) h = 0;
      return DateTime(y, mo, d, h, mi, s);
    }
    return null;
  }
}

/// Graph measure matching the website Employee Performance Graph dropdown.
enum EmployeeGraphMeasure {
  workMinutes('Work Minutes'),
  billsToday('Bills Today'),
  billsMonth('Bills (Month)'),
  totalBills('Total Bills'),
  activeSessions('Active Sessions'),
  avgWorkMinutesToday('Avg Work Minutes (Today)'),
  halfBillingMonth('Half Billing (Month)'),
  fullBillingMonth('Full Billing (Month)'),
  count('Count');

  const EmployeeGraphMeasure(this.label);
  final String label;
}
