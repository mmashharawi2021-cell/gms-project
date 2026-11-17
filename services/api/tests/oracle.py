"""Independent Decimal accounting oracle (SRS 17.2). Shares NO code with the SQL engine."""
from decimal import ROUND_DOWN, Decimal, getcontext

getcontext().prec = 40
D = Decimal


class LedgerOracle:
    def __init__(self):
        self.movements: list[Decimal] = []

    def post(self, amount) -> None:
        amount = D(str(amount))
        if amount != 0:
            self.movements.append(amount)

    def charge(self, kwh, rate) -> Decimal:
        amount = D(str(kwh)) * D(str(rate))
        self.post(amount)
        return amount

    @property
    def balance(self) -> Decimal:
        return sum(self.movements, D(0))

    @property
    def requested(self) -> Decimal:
        return max(D(0), self.balance.to_integral_value(rounding=ROUND_DOWN))

    @property
    def carried(self) -> Decimal:
        b = self.balance
        return b - b.to_integral_value(rounding=ROUND_DOWN) if b > 0 else D(0)

    @property
    def credit(self) -> Decimal:
        return max(D(0), -self.balance)
