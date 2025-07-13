import 'package:flutter/material.dart';

import '../../internal/hive.dart';
import '../../widget/sliver_pinned_header.dart';

class SelectDateTimeMode extends StatelessWidget {
  const SelectDateTimeMode({super.key});

  @override
  Widget build(BuildContext context) {
    final selectedMode = MyHive.getDateTimeMode();
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverPinnedAppBar(title: '日期样式'),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final mode = DateTimeMode.values[index];
                return RadioListTile<DateTimeMode>(
                  title: Text(mode.label),
                  value: mode,
                  groupValue: selectedMode,
                  onChanged: (value) {
                    MyHive.setDateTimeMode(mode);
                    Navigator.pop(context);
                  },
                );
              },
              childCount: DateTimeMode.values.length,
            ),
          ),
        ],
      ),
    );
  }
}
