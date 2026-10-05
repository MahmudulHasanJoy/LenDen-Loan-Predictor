"""Project-wide constants: columns, costs, paths and the input schema."""
from pathlib import Path

RANDOM_STATE = 42

ROOT = Path(__file__).resolve().parents[2]
DATA_PATH = ROOT / "data" / "Loan_default.csv"
ARTIFACT_DIR = ROOT / "artifacts"
MODEL_PATH = ARTIFACT_DIR / "model.joblib"
METRICS_PATH = ARTIFACT_DIR / "metrics.json"

TARGET = "Default"
ID_COLS = ["LoanID"]

NUM_COLS = ["Age", "Income", "LoanAmount", "CreditScore", "MonthsEmployed",
            "NumCreditLines", "InterestRate", "LoanTerm", "DTIRatio"]
CAT_COLS = ["Education", "EmploymentType", "MaritalStatus", "HasMortgage",
            "HasDependents", "LoanPurpose", "HasCoSigner"]
FEATURES = NUM_COLS + CAT_COLS

# Business costs (USD). Replace with figures from real loss data.
COST_FN = 10_000   # approved a loan that defaulted
COST_FP = 500      # rejected / sent to review an applicant who would have repaid

# Friendly labels used by the API and the mobile app.
LABELS = {
    "Age": "Age",
    "Income": "Annual income",
    "LoanAmount": "Loan amount",
    "CreditScore": "Credit score",
    "MonthsEmployed": "Months employed",
    "NumCreditLines": "Open credit lines",
    "InterestRate": "Interest rate (%)",
    "LoanTerm": "Loan term (months)",
    "DTIRatio": "Debt-to-income ratio",
    "Education": "Education",
    "EmploymentType": "Employment type",
    "MaritalStatus": "Marital status",
    "HasMortgage": "Has a mortgage",
    "HasDependents": "Has dependents",
    "LoanPurpose": "Loan purpose",
    "HasCoSigner": "Has a co-signer",
}

# Features treated as sensitive in the fairness audit (protected-class proxies).
SENSITIVE = ["AgeBand", "MaritalStatus", "HasDependents"]
