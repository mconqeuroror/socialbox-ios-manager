#!/usr/bin/env python3
"""Read-only, two-architecture verification of the pinned per-app stop boundary.

Supply the private original executable; it is never loaded or executed. Method
addresses come from Objective-C metadata, branch destinations from instructions.
This does not prove storage/network isolation or execute the original worker.
"""
import argparse,hashlib,json,re,struct
from pathlib import Path
from enumerate_leak_binary import MachO,macho_slices,cstr
ROOT=Path(__file__).resolve().parents[1]
HOST_SHA='e230dab07690e30c292962a3c0a3ea8301f9532aaa583a7209fdf33142552dd0'

def methods(m):
    section=next(s for s in m.sections if s['name']=='__objc_classlist')
    for off in range(section['offset'],section['offset']+section['size'],8):
        va,_=m.pointer(off)
        if m.class_name(va)!='_Xr4s':continue
        ro,_=m.pointer(m.vaoff(va)+32);table,_=m.pointer(m.vaoff(ro&~7)+32)
        flags,count=struct.unpack_from('<II',m.data,m.vaoff(table))
        assert flags==0x8000000c,'Unexpected method layout'
        result={}
        for i in range(count):
            at=table+8+i*12;name,encoding,imp=struct.unpack_from('<iii',m.data,m.vaoff(at))
            selector,_=m.pointer(m.vaoff(at+name))
            result[cstr(m.data,m.vaoff(selector))]=(at+8+imp,cstr(m.data,m.vaoff(at+4+encoding)))
        return result
    raise ValueError('Missing exact manager class')

def signed(value,bits):return value-(1<<bits) if value&(1<<(bits-1)) else value
def branch(m,address,opcode):
    word=struct.unpack_from('<I',m.data,m.vaoff(address))[0]
    if opcode=='cbz':
        assert word&0xff00001f==0xb4000000,'Wait must branch on zero x0 only'
        return address+4*signed((word>>5)&0x7ffff,19)
    assert word&0xfc000000=={'b':0x14000000,'bl':0x94000000}[opcode],'Unexpected direct branch'
    return address+4*signed(word&0x3ffffff,26)

def verify(raw):
    assert hashlib.sha256(raw).hexdigest()==HOST_SHA,'Wrong baseline executable'
    source=(ROOT/'lucid/HelperSafety/LBXAppSwitchSafety.m').read_text()
    sites=re.findall(r'static const LBXSwitchSite LBXArm(64e?)Site=\{\s*([\dxabcdef,\s]+),\s*"([a-f0-9]{64})",\s*"([a-f0-9]{64})",\s*"([a-f0-9]{64})",(\d+)\};',source)
    assert len(sites)==2,'Unreviewed source contract format'
    contracts={name:([int(v.strip(),0) for v in fields.split(',')],wh,sh,fh,int(fs)) for name,fields,wh,sh,fh,fs in sites}
    result=[]
    for _,part in macho_slices(raw):
        m=MachO(part);arch={0:'64',2:'64e'}[m.subtype&0xffffff];base=m.image_base
        fields,worker_hash,stub_hash,failure_hash,failure_size=contracts[arch]
        getter,entry,return_pc,worker,size,stub,failure=fields
        recovered=methods(m)
        assert recovered['helperProxy']==(base+getter,'@16@0:8')
        assert recovered['switchApp:toContainer:progress:completion:']==(base+entry,'v48@0:8@16q24@?32@?40')
        metadata=re.findall(r'base\+\(subtype==0\?(0x[0-9a-f]+):(0x[0-9a-f]+)\)',source)
        assert len(metadata)==3,'Unreviewed metadata binding expression'
        for index,(name,abi) in enumerate([('globalMetadataPath','@16@0:8'),('writeGlobalMetadata:','B24@0:8@16'),('mutateGlobalMetadataLocked:','B24@0:8@?16')]):
            assert recovered[name]==(base+int(metadata[index][arch=='64e'],16),abi),'Wrong metadata method/ABI'
        for offset,length,expected in [(worker,size,worker_hash),(stub,32,stub_hash),(failure,failure_size,failure_hash)]:
            start=m.vaoff(base+offset)
            assert hashlib.sha256(part[start:start+length]).hexdigest()==expected,'Changed worker/stub/failure body'
        assert branch(m,base+return_pc-4,'bl')==base+stub,'Getter interception is not the actual worker callsite'
        wait,abort_end,success,cleanup=(0x229cc0,0x229d28,0x229d2c,0x22a4d4) if arch=='64' else (0x22f55c,0x22f5dc,0x22f5e0,0x230074)
        branch(m,base+wait,'bl')
        assert branch(m,base+wait+4,'cbz')==base+success
        assert branch(m,base+abort_end,'b')==base+cleanup
        # Completion receives false in w1 before its final indirect tail call.
        word=struct.unpack_from('<I',part,m.vaoff(base+failure+failure_size-8))[0]
        assert word==0x52800001,'Failure completion must report NO'
        result.append({'architecture':'arm'+arch,'managerMethods':'MATCH','sourceCodePins':'MATCH',
            'getterReturnPC':hex(base+return_pc),'timeoutSkipsSuccessBlock':True,'failureCompletionBOOL':False,
            'globalMetadataMethods':'MATCH','originalWorkerExecuted':False,'networkOrStorageIsolationProven':False})
    assert {row['architecture'] for row in result}=={'arm64','arm64e'}
    return {'status':'PASS_STATIC_TWO_ARCHITECTURE_BOUNDARY','originalSHA256':HOST_SHA,'results':result}
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('binary',type=Path);args=parser.parse_args()
    print(json.dumps(verify(args.binary.read_bytes()),indent=2))
