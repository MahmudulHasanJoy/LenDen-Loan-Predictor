import 'package:flutter/material.dart';

import 'check_screen.dart';
import 'emi_screen.dart';
import 'my_applications_screen.dart';

/// Borrower ("general mode") shell: check readiness, track applications, EMI calculator.
class BorrowerHome extends StatefulWidget {
  const BorrowerHome({super.key});

  @override
  State<BorrowerHome> createState() => _BorrowerHomeState();
}

class _BorrowerHomeState extends State<BorrowerHome> {
  int _tab = 0;
  int _appsVersion = 0; // bump to refresh "My applications" after applying

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          CheckScreen(
            embedded: true,
            onApplied: () => setState(() {
              _appsVersion++;
              _tab = 1;
            }),
          ),
          MyApplicationsScreen(key: ValueKey(_appsVersion)),
          const EmiScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.speed), label: 'Check'),
          NavigationDestination(icon: Icon(Icons.description_outlined), label: 'My applications'),
          NavigationDestination(icon: Icon(Icons.calculate_outlined), label: 'EMI'),
        ],
      ),
    );
  }
}
