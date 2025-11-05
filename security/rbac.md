# Role-Based Access Control (RBAC) and Data Tiering for HIPAA-Compliant Systems

**Version:** 1.0  
**Author:** Lazybaer (Christopher W. DeLaurentis)  
**Scope:** HIPAA / HITECH / PHI / PII Data Governance  

---

## 1. Purpose

This document defines the role-based access control (RBAC) structure and data tiering model for systems handling **Protected Health Information (PHI)** and **Personally Identifiable Information (PII)**.  
It enforces HIPAA’s *minimum necessary* standard and HITECH’s data protection requirements through clearly delineated access tiers.

---

## 2. Core Principles

1. **Least Privilege:** Each user is granted the minimum access necessary to perform their duties.  
2. **Segregation of Duties:** Clinical, administrative, billing, and IT roles are functionally isolated.  
3. **Accountability:** Every data access event is logged and auditable.  
4. **Data Segmentation:** Contact/PII, financial, and PHI data are logically or physically separated.  
5. **Defense in Depth:** Administrative, technical, and physical controls are layered for redundancy.

---

## 3. Data Domains

| **Domain** | **Description** |
|-------------|-----------------|
| **Demographics & Contact Info** | Names, addresses, phone numbers, DOB, gender, emergency contacts |
| **Scheduling & Appointments** | Visit slots, provider assignment, location/time |
| **Insurance / Billing Info** | Payer data, claims, co-pays, CPT/ICD codes |
| **Clinical Encounters & Diagnoses** | SOAP notes, vitals, diagnosis, prescriptions |
| **Lab / Imaging Results** | Diagnostic results, uploaded files |
| **Messages / Communications** | Patient–provider communications, care instructions |
| **Audit Logs / Config** | System logs, configuration data, access records |

---

## 4. Tier Definitions

| **Tier** | **Description** |
|-----------|-----------------|
| **Tier 0 — Patient Access** | Limited to self-view; patient portal access to their own data. |
| **Tier 1 — Administrative Access (Front Desk / Scheduler)** | Handles demographic and scheduling data; no PHI. |
| **Tier 2 — Billing / Insurance Access** | Access to limited PHI related to claims and payments. |
| **Tier 2.5 — Clinical Support Access** | Medical assistants or techs who prep or record limited PHI under clinician supervision. |
| **Tier 3 — Clinician Access** | Full PHI access for treatment, documentation, and clinical decision-making. |
| **Tier 4 — Admin / Security Access** | System-level oversight and audit capability, not clinical data access. |

---

## 5. Role–Data–Permission Matrix

| **Role / Tier** | **Demographics & Contact Info** | **Scheduling & Appointments** | **Insurance / Billing Info** | **Clinical Encounters & Diagnoses** | **Lab / Imaging Results** | **Messages / Communications** | **Audit Logs / Config** | **Notes** |
|------------------|--------------------------------|-------------------------------|------------------------------|-------------------------------------|----------------------------|--------------------------------|--------------------------|------------|
| **Front Desk / Scheduler (Tier 1)** | R/W | R/W | R (coverage validation only) | ✖️ | ✖️ | R/W (logistics only) | ✖️ | No PHI beyond identifying data. |
| **Billing / Insurance (Tier 2)** | R | R | R/W | R (encounter summary only) | ✖️ | R (insurance comms) | ✖️ | Access CPT/ICD for claims only. |
| **Clinical Support (Tier 2.5)** | R/W | R/W | R | R/W (intake, vitals) | R | R/W (with supervision) | ✖️ | Limited PHI, supervised access. |
| **Clinician (Tier 3)** | R/W | R/W | R/W | R/W | R/W | R/W | ✖️ | Full PHI; audited and logged. |
| **Admin / IT / Security (Tier 4)** | ✖️ (metadata only) | ✖️ | ✖️ | ✖️ | ✖️ | ✖️ | R/W (system only) | Troubleshooting under policy only. |
| **Patient / Portal User (Tier 0)** | R (self) | R (self) | R (self billing) | R (self) | R (self) | R/W (self messages) | ✖️ | Access to own record only. |

Legend:  
**R** = Read, **W** = Write, **✖️** = No Access.  
All permissions default to **deny** unless explicitly granted.

---

## 6. Technical Implementation

### 6.1 Access Enforcement
- Implement **RBAC** at the service layer; overlay with **ABAC** for contextual restrictions (e.g., facility, provider, patient ownership).
- Enforce **deny by default**: roles gain access only through explicit grants.
- Define permissions in centralized configuration (policy files, IAM roles, or database ACLs).

### 6.2 Data Segmentation
| **Data Type** | **Segmentation Strategy** |
|----------------|---------------------------|
| PII | Stored in separate schema or service (e.g., `users.demographics`) |
| PHI | Stored in encrypted clinical data service |
| Audit / Config | Stored in immutable log store (WORM or append-only) |

### 6.3 Security Controls
- **Encryption:** AES-256 at rest, TLS 1.2+ in transit.  
- **Authentication:** Unique user IDs, MFA, session timeouts.  
- **Authorization:** Tokenized sessions bound to RBAC/ABAC context.  
- **Audit Trails:** Every PHI read/write logged (user ID, patient ID, timestamp, action).  
- **Masking:** Hide DOB, SSN, or insurance IDs for Tier 1 users.  
- **Monitoring:** Automated anomaly detection (e.g., scheduler accessing hundreds of patient charts).  

---

## 7. Administrative Controls

| **Policy Area** | **Implementation** |
|------------------|--------------------|
| **Workforce Security** | Provision/deprovision accounts via identity management system; enforce least privilege. |
| **Training** | All workforce members receive HIPAA awareness training. |
| **Review** | Quarterly access reviews and re-authorization. |
| **BAAs** | Business Associate Agreements required for all 3rd-party data processors. |
| **Incident Response** | Access logs support investigation and breach notification under HITECH. |

---

## 8. HIPAA Compliance Mapping

| **HIPAA Rule (45 CFR)** | **Control Implemented** |
|--------------------------|-------------------------|
| **164.308(a)(3)** Workforce security | Role-based access with least privilege |
| **164.308(a)(4)** Information access management | Explicit role authorization |
| **164.308(a)(5)** Security awareness | Workforce training |
| **164.312(a)(1)** Access control | Unique user IDs & RBAC |
| **164.312(b)** Audit controls | Centralized audit logging |
| **164.312(c)(1)** Integrity | Controlled write operations |
| **164.312(d)** Person/entity authentication | MFA, ID verification |
| **164.312(e)** Transmission security | Encrypted communication channels |

---

## 9. Audit & Monitoring

- **Continuous monitoring:** Real-time audit of PHI access events.  
- **Automated anomaly alerts:** Volume thresholds and behavioral triggers.  
- **Quarterly audit:** Manual review of Tier 2–4 access logs.  
- **Immutable retention:** Minimum 6 years per HIPAA §164.316(b)(2)(i).

---

## 10. Enforcement & Governance

- Violations of this RBAC policy constitute a HIPAA compliance incident.  
- Enforcement actions include suspension of access, retraining, or termination.  
- The Security Officer and Privacy Officer jointly review role assignments.  
- Any role expansion requires written approval and audit logging.

---

## 11. Future Enhancements

- Integrate **Open Policy Agent (OPA)** for centralized policy evaluation.  
- Automate **role assignment via HRIS events** (hire, transfer, termination).  
- Expand **Tier 4 observability** with immutable blockchain-style audit proofs.  

---

## 12. References

- HIPAA Security Rule – 45 CFR §164.308–312  
- HITECH Act – Public Law 111-5  
- NIST SP 800-53 Rev 5 (Access Control / Audit / Identification)  
- NIST SP 800-66r2 (Implementing the HIPAA Security Rule)  
- HHS Guidance on Minimum Necessary Standard (2013)
