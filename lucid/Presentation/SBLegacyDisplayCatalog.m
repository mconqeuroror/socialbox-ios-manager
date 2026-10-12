#import "SBLegacyDisplayCatalog.h"
#import <CommonCrypto/CommonDigest.h>

static NSDictionary<NSString *, NSString *> *FixedCopy(void) {
    static NSDictionary *copy; static dispatch_once_t once;
    dispatch_once(&once, ^{
        copy=@{
            @"Spoofing Settings":@"Identity",
            @"LocSim":@"Location",
            @"Start simulation":@"Start simulation",
            @"Start Simulation":@"Start simulation",
            @"Stop simulation":@"Stop simulation",
            @"Stop Simulation":@"Stop simulation",
            @"No importable container archives found. Save an archive to Downloads in Files, then try again.":@"No importable container archives found. Save an archive to Downloads in Files, then try again.",
            @"This container archive is invalid or damaged.":@"This container archive is invalid or damaged.",
            @"The background service is not responding. Containers cannot be switched safely. Try again or restart the device.":@"The background service is not responding. Containers cannot be switched safely. Try again or restart the device.",
        };
    });
    return copy;
}

NSString *SBLegacyFixedDisplayText(NSString *text) {
    return text ? (FixedCopy()[text] ?: text) : nil;
}

static NSString *MapEnvelope(NSString *text, NSString *prefix, NSString *suffix,
                            NSString *newPrefix, NSString *newSuffix) {
    if((prefix.length && ![text hasPrefix:prefix]) || (suffix.length && ![text hasSuffix:suffix])
        || text.length<prefix.length+suffix.length) return nil;
    NSString *value=[text substringWithRange:NSMakeRange(prefix.length,text.length-prefix.length-suffix.length)];
    return [NSString stringWithFormat:@"%@%@%@",newPrefix,value,newSuffix];
}

NSString *SBLegacyReviewedDisplayText(NSString *text) {
    if(!text) return nil;
    NSString *fixed=FixedCopy()[text]; if(fixed) return fixed;
    NSString *mapped=MapEnvelope(text,@"Couldn't reach SocialBoxHelper: ",@"",@"Couldn't reach the background service: ",@"");
    if(mapped) return mapped;
    mapped=MapEnvelope(text,@"source .socialbox missing: ",@"",@"Source archive missing: ",@"");
    if(mapped) return mapped;
    mapped=MapEnvelope(text,@"Removing \"",@"\" from SocialBox Cloud.",@"Removing \"",@"\" from Cloud.");
    if(mapped) return mapped;
    mapped=MapEnvelope(text,@"\"",@"\" is now in SocialBox Cloud. You can restore it on any device with this license + your passphrase.",@"\"",@"\" is now in Cloud. Restore it on another device using this license and your passphrase.");
    if(mapped) return mapped;
    mapped=MapEnvelope(text,@"\"",@"\" will be permanently removed from the SocialBox Cloud server and one quota slot will be freed. This CANNOT be undone — even with the passphrase, the backup can't be recovered after deletion.\n\nLocal containers on this device are NOT affected.",@"\"",@"\" will be permanently deleted from Cloud, freeing one quota slot. This cannot be undone, even with the passphrase. Local containers on this device are not affected.");
    if(mapped) return mapped;
    mapped=MapEnvelope(text,@"",@"\n\n• SAME DEVICE — tap Import (top-left in Containers). This export is already listed there.\n\n• ANOTHER DEVICE — tap Open Files below. In Files, tap the .socialbox file, then AirDrop it. The receiving device will offer 'Open in SocialBox' automatically.",@"",@"\n\nOn this device, open Containers and tap Import. To transfer the archive, tap Open Files and share it with the other device. Open the received archive in SocialBox.");
    if(mapped) return mapped;
    mapped=MapEnvelope(text,@"",@"\n\n• SAME DEVICE — tap Import (top-left in Containers). This bundle is already listed there.\n\n• ANOTHER DEVICE — tap Open Files below. In Files, navigate to \"On My iPhone → SocialBox\", tap the .socialboxpack, then AirDrop it. The receiving device will offer 'Open in SocialBox' automatically.",@"",@"\n\nOn this device, open Containers and tap Import. To transfer the archive, tap Open Files and share it with the other device. Open the received archive in SocialBox.");
    return mapped ?: text;
}

static NSString *Reference(NSString *text) {
    NSData *bytes=[text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    return [NSString stringWithFormat:@"SB-%02X%02X%02X%02X",digest[0],digest[1],digest[2],digest[3]];
}

NSString *SBLegacyStatusDisplayText(NSString *text) {
    if(!text) return nil;
    NSString *reviewed=SBLegacyReviewedDisplayText(text);
    if(![reviewed isEqual:text]) return reviewed;
    return text;
}

NSString *SBLegacyDiagnosticDisplayText(NSString *text) {
    if(!text) return nil;
    NSString *fixed=FixedCopy()[text]; if(fixed) return fixed;
    if([FixedCopy().allValues containsObject:text] || [text isEqual:@"The source container archive could not be found."]) return text;
    NSString *referencePrefix=@"The operation could not be completed. Reference: SB-";
    if([text hasPrefix:referencePrefix] && text.length==referencePrefix.length+8
        && [[text substringFromIndex:referencePrefix.length] rangeOfCharacterFromSet:
            [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet]].location==NSNotFound) return text;
    for(NSString *prefix in @[@"Couldn't reach SocialBoxHelper: ",@"Couldn't reach the background service: "])
        if([text hasPrefix:prefix]) {
            NSString *cause=[text substringFromIndex:prefix.length];
            if([@[@"timeout",@"connection refused",@"service unavailable"] containsObject:cause])
                return [@"Couldn't reach the background service: " stringByAppendingString:cause];
        }
    if([text hasPrefix:@"source .socialbox missing: "]) return @"The source container archive could not be found.";
    if([text rangeOfString:@"password="].location!=NSNotFound)
        return [@"The operation could not be completed. Reference: " stringByAppendingString:Reference(text)];
    return [@"The operation could not be completed. Reference: " stringByAppendingString:Reference(text)];
}
