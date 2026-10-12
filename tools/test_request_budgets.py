#!/usr/bin/env python3
"""Clone rebuilding needs the same bounded budget as clone creation."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'daemon/main.m').read_text();start=s.index('static NSTimeInterval requestBudget(');end=s.index('\n}',start)+2
source='#import <Foundation/Foundation.h>\n'+s[start:end]+'''\nint main(){@autoreleasepool{
 if(requestBudget(@"applyIdentity")!=requestBudget(@"createContainer"))return 1;
 if(requestBudget(@"applyIdentity")!=600 || requestBudget(@"deleteContainer")!=240 || requestBudget(@"runDiagnostics")!=60 || requestBudget(@"loadIdentityEditor")!=120)return 2;
 puts("PASS: rebuild shares bounded creation budget; shorter read/diagnostic budgets unchanged");return 0;
}}'''
with tempfile.TemporaryDirectory(prefix='rbx-request-budget-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(source);subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True);subprocess.run([str(p/'test')],check=True)
