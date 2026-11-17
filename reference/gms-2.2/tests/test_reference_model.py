"""Independent Decimal accounting oracle. Not a PostgreSQL test."""
from decimal import Decimal, getcontext, ROUND_DOWN
import pathlib
import unittest

getcontext().prec = 36
D = Decimal

class Ledger:
    def __init__(self, opening='0'):
        self.movements = [D(opening)] if D(opening) else []
    def charge(self, amount):
        assert D(amount) >= 0
        self.movements.append(D(amount))
    def payment(self, amount):
        assert D(amount) > 0
        self.movements.append(-D(amount))
    def adjustment(self, amount):
        assert D(amount) != 0
        self.movements.append(D(amount))
    @property
    def balance(self):
        return sum(self.movements, D(0))
    @property
    def requested(self):
        return max(D(0), self.balance.to_integral_value(rounding=ROUND_DOWN))
    @property
    def carried(self):
        return max(D(0), self.balance - self.balance.to_integral_value(rounding=ROUND_DOWN))
    @property
    def credit(self):
        return max(D(0), -self.balance)

class TestFinancialModel(unittest.TestCase):
    def test_fraction_across_paid_cycles(self):
        l=Ledger();l.charge('21.45')
        self.assertEqual((l.requested,l.carried),(D(21),D('.45')))
        l.payment('21'); l.charge('15.80')
        self.assertEqual((l.requested,l.carried),(D(16),D('.25')))
    def test_credit_with_future_cycles(self):
        l=Ledger(); l.charge('40');l.payment('40');l.adjustment('-8');l.charge('5')
        self.assertEqual((l.requested,l.credit),(D(0),D(3)))
        l.charge('2');self.assertEqual(l.credit,D(1))
    def test_partial_payment_preserves_debt(self):
        l=Ledger();l.charge('150.25');l.payment('100')
        self.assertEqual((l.requested,l.carried),(D(50),D('.25')))
    def test_zero_consumption_does_not_lose_fraction(self):
        l=Ledger('.45');l.charge('0')
        self.assertEqual((l.requested,l.carried),(D(0),D('.45')))
    def test_correction_closed_as_independent_entry(self):
        l=Ledger();l.charge('40');l.payment('40');l.adjustment('-8')
        self.assertEqual(len(l.movements),3)
        self.assertEqual(l.credit,D(8))
    def test_multiple_readings_one_week(self):
        previous=D('100.00')
        readings=[D('101.20'),D('101.43')]
        kwh=[]
        for current in readings:
            kwh.append(current-previous)
            previous=current
        self.assertEqual(sum(kwh),D('1.43'))
        self.assertEqual(sum(kwh)*D('15'),D('21.45'))
    def test_week_of_current_reading(self):
        # 10 kWh between weeks: use final price of current reading week.
        self.assertEqual((D(110)-D(100))*D(25),D(250))

class TestStaticSQLCoverage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root=pathlib.Path(__file__).resolve().parents[1]
        cls.base=(root/'10_baseline.sql').read_text()
        cls.harden=(root/'20_hardening.sql').read_text()
        cls.engine=(root/'30_financial_engine.sql').read_text()
    def test_raw_readings_no_numeric_typmod(self):
        self.assertNotIn('numeric(18,2)',self.base)
        self.assertIn('scale(reading_value_kwh) <= 2',self.harden)
    def test_critical_triggers_present(self):
        for trigger in ['trg_gms_immutable_visits','trg_gms_approved_append_only',
                        'trg_gms_statement_protection','trg_gms_price_lock',
                        'trg_gms_ledger_valid_source','trg_gms_allocation_guard']:
            self.assertIn(trigger,self.harden)
    def test_finance_functions_present(self):
        for name in ['gms_finalize_cycle','gms_record_payment','gms_reverse_payment',
                     'gms_record_adjustment','gms_approve_visit','gms_receive_visit']:
            self.assertIn('FUNCTION '+name,self.engine)
    def test_no_application_direct_dml_default(self):
        self.assertIn('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC',self.harden)
    def test_expected_dollar_delimiters_balanced(self):
        for text in [self.base,self.harden,self.engine]:
            self.assertEqual(text.count('$$')%2,0)

if __name__=='__main__':unittest.main()
