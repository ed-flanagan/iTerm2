//
//  iTermMetadata.h
//  iTerm2SharedARC
//
//  Created by George Nachman on 9/15/21.
//

#import <Foundation/Foundation.h>
#include <simd/vector_types.h>
#import "VT100GridTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface iTermExternalAttribute: NSObject<NSCopying>
@property (nonatomic) BOOL hasUnderlineColor;
@property (nonatomic) vector_float4 underlineColor;

@property(nonatomic, readonly) NSDictionary *dictionaryValue;
@end

@interface iTermExternalAttributeIndex: NSObject<NSCopying>
@property (nonatomic, strong) NSDictionary<NSNumber *, iTermExternalAttribute *> *attributes;
@property (nonatomic, readonly) NSDictionary *dictionaryValue;

+ (instancetype)withDictionary:(NSDictionary *)dictionary;  // return nil if input is NSNull
- (instancetype)initWithDictionary:(NSDictionary *)dictionary;

- (void)eraseAt:(int)x;
- (void)eraseInRange:(VT100GridRange)range;
- (void)setAttributes:(iTermExternalAttribute *)attributes at:(int)cursorX count:(int)count;
- (void)copyFrom:(iTermExternalAttributeIndex *)source
          source:(int)source
     destination:(int)destination
           count:(int)count;
- (iTermExternalAttributeIndex *)subAttributesFromIndex:(int)index;
- (iTermExternalAttributeIndex *)subAttributesFromIndex:(int)index maximumLength:(int)maxLength;
- (iTermExternalAttribute * _Nullable)objectAtIndexedSubscript:(NSInteger)idx;
+ (iTermExternalAttributeIndex *)concatenationOf:(iTermExternalAttributeIndex *)lhs
                                      length:(int)lhsLength
                                        with:(iTermExternalAttributeIndex *)rhs
                                      length:(int)rhsLength;
@end


@interface iTermMetadata : NSObject
@property (nonatomic) NSTimeInterval timestamp;
@property (nullable, strong) iTermExternalAttributeIndex *externalAttributes;
@property (nonatomic, readonly) NSArray *arrayValue;

+ (instancetype)metadataWithTimestamp:(NSTimeInterval)timestamp
                   externalAttributes:(iTermExternalAttributeIndex * _Nullable)externalAttributes;
+ (instancetype)metadataWithArray:(NSArray *)array;
+ (instancetype)defaultMetadata;

- (iTermExternalAttributeIndex *)externalAttributesCreatingIfNeeded;
- (iTermExternalAttributeIndex * _Nullable)externalAttributesCreatingIfNeeded:(BOOL)createIfNeeded;
- (iTermMetadata *)subMetadataFromIndex:(NSInteger)start maximumLength:(NSInteger)maximumLength;
- (iTermMetadata *)metadataByAppending:(iTermMetadata *)rhs
                              myLength:(int)lhsLength
                        appendeeLength:(int)rhsLength;

- (void)reset;

@end

@interface iTermUniformExternalAttributes: iTermExternalAttributeIndex
+ (instancetype)withAttribute:(iTermExternalAttribute *)attr;

- (void)copyFrom:(iTermExternalAttributeIndex *)source
          source:(int)loadBase
     destination:(int)storeBase
           count:(int)count NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
