//
//  ORunner+Execute.m
//  MangoFix
//
//  Created by Jiang on 2020/5/8.
//  Copyright © 2020 yongpengliang. All rights reserved.
//

#import "RunnerClasses+Execute.h"
#import "MFScopeChain.h"
#import "util.h"
#import "MFMethodMapTable.h"
#import "MFPropertyMapTable.h"
#import "MFVarDeclareChain.h"
#import "MFWeakPropertyBox.h"
#import "MFBlock.h"
#import "MFValue.h"
#import "MFStaticVarTable.h"
#import "ORStructDeclare.h"
#import <objc/message.h>
#import "ORTypeVarPair+TypeEncode.h"

static MFValue *invoke_sueper_values(id instance, SEL sel, NSArray<MFValue *> *argValues){
    BOOL isClassMethod = object_isClass(instance);
    Class superClass;
    if (isClassMethod) {
        superClass = class_getSuperclass(instance);
    }else{
        superClass = class_getSuperclass([instance class]);
    }
    struct objc_super *superPtr = &(struct objc_super){instance,superClass};
    NSMethodSignature *sig = [instance methodSignatureForSelector:sel];
    NSUInteger argCount = sig.numberOfArguments;
    
    void **args = alloca(sizeof(void *) * argCount);
    ffi_type **argTypes = alloca(sizeof(ffi_type *) * argCount);
    
    argTypes[0] = &ffi_type_pointer;
    args[0] = &superPtr;
    
    argTypes[1] = &ffi_type_pointer;
    args[1] = &sel;
    
    for (NSUInteger i = 2; i < argCount; i++) {
        MFValue *argValue = argValues[i-2];
        char *argTypeEncoding = (char *)[sig getArgumentTypeAtIndex:i];
        argTypeEncoding = removeTypeEncodingPrefix(argTypeEncoding);
#define mf_SET_FFI_TYPE_AND_ARG_CASE(_code,_ffi_type_value)\
case _code:{\
argTypes[i] = &_ffi_type_value;\
args[i] = argValue.pointer;\
break;\
}
        switch (*argTypeEncoding) {
                mf_SET_FFI_TYPE_AND_ARG_CASE('c', ffi_type_schar)
                mf_SET_FFI_TYPE_AND_ARG_CASE('i', ffi_type_sint)
                mf_SET_FFI_TYPE_AND_ARG_CASE('s', ffi_type_sshort)
                mf_SET_FFI_TYPE_AND_ARG_CASE('l', ffi_type_slong)
                mf_SET_FFI_TYPE_AND_ARG_CASE('q', ffi_type_sint64)
                mf_SET_FFI_TYPE_AND_ARG_CASE('C', ffi_type_uchar)
                mf_SET_FFI_TYPE_AND_ARG_CASE('I', ffi_type_uint)
                mf_SET_FFI_TYPE_AND_ARG_CASE('S', ffi_type_ushort)
                mf_SET_FFI_TYPE_AND_ARG_CASE('L', ffi_type_ulong)
                mf_SET_FFI_TYPE_AND_ARG_CASE('Q', ffi_type_uint64)
                mf_SET_FFI_TYPE_AND_ARG_CASE('B', ffi_type_sint8)
                mf_SET_FFI_TYPE_AND_ARG_CASE('f', ffi_type_float)
                mf_SET_FFI_TYPE_AND_ARG_CASE('d', ffi_type_double)
            case '@':
            case ':':
            case '#':
            case '^':
            case '*':
            {
                argTypes[i] = &ffi_type_pointer;
                args[i] = argValue.pointer;
                break;
            }
            default:
                NSCAssert(0, @"not support type  %s", argTypeEncoding);
                break;
        }
        
    }
    
    char *returnTypeEncoding = (char *)[sig methodReturnType];
    returnTypeEncoding = removeTypeEncodingPrefix(returnTypeEncoding);
    ffi_type *rtype = NULL;
    void *rvalue = NULL;
#define mf_FFI_RETURN_TYPE_CASE(_code, _ffi_type)\
case _code:{\
rtype = &_ffi_type;\
rvalue = alloca(rtype->size);\
break;\
}
    
    switch (*returnTypeEncoding) {
            mf_FFI_RETURN_TYPE_CASE('c', ffi_type_schar)
            mf_FFI_RETURN_TYPE_CASE('i', ffi_type_sint)
            mf_FFI_RETURN_TYPE_CASE('s', ffi_type_sshort)
            mf_FFI_RETURN_TYPE_CASE('l', ffi_type_slong)
            mf_FFI_RETURN_TYPE_CASE('q', ffi_type_sint64)
            mf_FFI_RETURN_TYPE_CASE('C', ffi_type_uchar)
            mf_FFI_RETURN_TYPE_CASE('I', ffi_type_uint)
            mf_FFI_RETURN_TYPE_CASE('S', ffi_type_ushort)
            mf_FFI_RETURN_TYPE_CASE('L', ffi_type_ulong)
            mf_FFI_RETURN_TYPE_CASE('Q', ffi_type_uint64)
            mf_FFI_RETURN_TYPE_CASE('B', ffi_type_sint8)
            mf_FFI_RETURN_TYPE_CASE('f', ffi_type_float)
            mf_FFI_RETURN_TYPE_CASE('d', ffi_type_double)
            mf_FFI_RETURN_TYPE_CASE('@', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE('#', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE(':', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE('^', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE('*', ffi_type_pointer)
            mf_FFI_RETURN_TYPE_CASE('v', ffi_type_void)
        case '{':{
            rtype = mf_ffi_type_with_type_encoding(returnTypeEncoding);
            rvalue = alloca(rtype->size);
        }
            
        default:
            NSCAssert(0, @"not support type  %s", returnTypeEncoding);
            break;
    }
    ffi_cif cif;
    ffi_prep_cif(&cif, FFI_DEFAULT_ABI, (unsigned int)argCount, rtype, argTypes);
    ffi_call(&cif, objc_msgSendSuper, rvalue, args);
    MFValue *retValue;
    retValue = [[MFValue alloc] initTypeEncode:returnTypeEncoding pointer:rvalue];
    return retValue;
}

static MFValue * invoke_MFBlockValue(MFValue *blockValue, NSArray *args){
    const char *blockTypeEncoding = [MFBlock typeEncodingForBlock:blockValue.objectValue];
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:blockTypeEncoding];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    [invocation setTarget:blockValue.objectValue];
    NSUInteger numberOfArguments = [sig numberOfArguments];
    if (numberOfArguments - 1 != args.count) {
        //            mf_throw_error(expr.lineNumber, MFRuntimeErrorParameterListCountNoMatch, @"expect count: %zd, pass in cout:%zd",numberOfArguments - 1,expr.args.count);
        return [MFValue valueWithObject:nil];
    }
    //根据MFValue的type传入值的原因: 模拟在OC中的调用
    for (NSUInteger i = 1; i < numberOfArguments; i++) {
        MFValue *argValue = args[i -1];
        // 基础类型转换
        argValue.typeEncode = [sig getArgumentTypeAtIndex:i];
        [invocation setArgument:argValue.pointer atIndex:i];
    }
    [invocation invoke];
    const char *retType = [sig methodReturnType];
    retType = removeTypeEncodingPrefix((char *)retType);
    if (*retType == 'v') {
        return [MFValue voidValue];
    }
    void *retValuePtr = alloca(mf_size_with_encoding(retType));
    [invocation getReturnValue:retValuePtr];
    return [[MFValue alloc] initTypeEncode:retType pointer:retValuePtr];;
}
static void *add_function(const char *funcReturnType, NSMutableArray <NSString *>*argTypes, void (*executeFunc)(ffi_cif*,void*,void**,void*), NSDictionary *userInfo){
    void *imp = NULL;
    ffi_cif *cif = malloc(sizeof(ffi_cif));//不可以free
    ffi_closure *closure = ffi_closure_alloc(sizeof(ffi_closure), (void **)&imp);
    ffi_type *returnType = mf_ffi_type_with_type_encoding(funcReturnType);
    ffi_type **args = malloc(sizeof(ffi_type *) * (unsigned int)argTypes.count);
    for (int  i = 0 ; i < argTypes.count; i++) {
        args[i] = mf_ffi_type_with_type_encoding(argTypes[i].UTF8String);
    }
    if(ffi_prep_cif(cif, FFI_DEFAULT_ABI, (unsigned int)argTypes.count, returnType, args) == FFI_OK)
    {
        CFTypeRef cfuserInfo = (__bridge_retained CFTypeRef)userInfo;
        ffi_prep_closure_loc(closure, cif, executeFunc, (void *)cfuserInfo, imp);
    }
    return imp;
}
static void methodIMP(ffi_cif *cif, void *ret, void **args, void *userdata){
    NSDictionary * userInfo = (__bridge id)userdata;// 不可以进行释放
    Class class  = userInfo[@"class"];
    NSString *typeEncoding = userInfo[@"typeEncoding"];
    MFScopeChain *scope = userInfo[@"scope"];
    id assignSelf = (__bridge  id)(*(void **)args[0]);
    BOOL classMethod = object_isClass(assignSelf);
    if (classMethod) {
        [scope setValue:[MFValue valueWithClass:assignSelf] withIndentifier:@"self"];
    }else{
        [scope setValue:[MFValue valueWithObject:assignSelf] withIndentifier:@"self"];
    }
    SEL sel = *(void **)args[1];
    MFMethodMapTableItem *map = [[MFMethodMapTable shareInstance] getMethodMapTableItemWith:class classMethod:classMethod sel:sel];
    NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:typeEncoding.UTF8String];
    NSMutableArray<MFValue *> *argValues = [NSMutableArray array];
    NSUInteger numberOfArguments = [methodSignature numberOfArguments];
    // 在OC中，传入值都为原数值并非MFValue，需要转换
    for (NSUInteger i = 2; i < numberOfArguments; i++) {
        MFValue *argValue;
        const char *type = [methodSignature getArgumentTypeAtIndex:i];
        if (strcmp(type, "@?") == 0) {
            id block =  (__bridge id)(*(void **)args[i]);
            block = [block copy];
            argValue = [MFValue valueWithObject:block];
            argValue.type = TypeBlock;
        }else{
            void *arg = args[i];
            argValue = [[MFValue alloc] initTypeEncode:[methodSignature getArgumentTypeAtIndex:i] pointer:arg];
        }
        [argValues addObject:argValue];
    }
    [[MFStack argsStack] push:argValues];
    __autoreleasing MFValue *retValue = [map.methodImp execute:scope];
    [retValue writePointer:ret typeEncode:[methodSignature methodReturnType]];
}


static void replace_method(Class clazz, ORMethodImplementation *methodImp, MFScopeChain *scope){
    ORMethodDeclare *declare = methodImp.declare;
    NSString *methodName = declare.selectorName;
    SEL sel = NSSelectorFromString(methodName);
    
    MFMethodMapTableItem *item = [[MFMethodMapTableItem alloc] initWithClass:clazz method:methodImp];
    [[MFMethodMapTable shareInstance] addMethodMapTableItem:item];
    
    BOOL needFreeTypeEncoding = NO;
    const char *typeEncoding;
    Method ocMethod;
    if (methodImp.declare.isClassMethod) {
        ocMethod = class_getClassMethod(clazz, sel);
    }else{
        ocMethod = class_getInstanceMethod(clazz, sel);
    }
    if (ocMethod) {
        typeEncoding = method_getTypeEncoding(ocMethod);
    }else{
        typeEncoding = methodImp.declare.returnType.typeEncode;
        needFreeTypeEncoding = YES;
        typeEncoding = mf_str_append(typeEncoding, "@"); //self
        typeEncoding = mf_str_append(typeEncoding, ":"); //_cmd
        for (ORTypeVarPair *pair in methodImp.declare.parameterTypes) {
            const char *paramTypeEncoding = pair.typeEncode;
            const char *beforeTypeEncoding = typeEncoding;
            typeEncoding = mf_str_append(typeEncoding, paramTypeEncoding);
            free((void *)beforeTypeEncoding);
            free((void *)paramTypeEncoding);
        }
    }
    Class c2 = methodImp.declare.isClassMethod ? objc_getMetaClass(class_getName(clazz)) : clazz;
    if (class_respondsToSelector(c2, sel)) {
        NSString *orgSelName = [NSString stringWithFormat:@"ORG%@",methodName];
        SEL orgSel = NSSelectorFromString(orgSelName);
        if (!class_respondsToSelector(c2, orgSel)) {
            class_addMethod(c2, orgSel, method_getImplementation(ocMethod), typeEncoding);
        }
    }
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:typeEncoding];
    NSMutableArray *argTypes = [NSMutableArray array];
    for (int  i = 0 ; i < sig.numberOfArguments; i++) {
        [argTypes addObject:[NSString stringWithUTF8String:[sig getArgumentTypeAtIndex:i]]];
    }
    NSDictionary *userInfo = @{@"class":c2,@"typeEncoding":@(typeEncoding), @"scope":scope};
    void *imp = add_function(sig.methodReturnType, argTypes, methodIMP, userInfo);
    class_replaceMethod(c2, sel, imp, typeEncoding);
    if (needFreeTypeEncoding) {
        free((void *)typeEncoding);
    }
}

void getterInter(ffi_cif *cif, void *ret, void **args, void *userdata){
    ORPropertyDeclare *propDef = (__bridge ORPropertyDeclare *)userdata;
    id _self = (__bridge id)(*(void **)args[0]);
    NSString *propName = propDef.var.var.varname;
    id propValue = objc_getAssociatedObject(_self, mf_propKey(propName));
    const char *type = propDef.var.typeEncode;
    __autoreleasing MFValue *value;
    if (!propValue) {
        value = [MFValue defaultValueWithTypeEncoding:type];
        [value writePointer:ret typeEncode:type];
    }else if(*type == '@'){
        if ([propValue isKindOfClass:[MFWeakPropertyBox class]]) {
            MFWeakPropertyBox *box = propValue;
            if (box.target) {
                *(void **)ret = (__bridge void *)box.target;
            }else{
                value = [MFValue defaultValueWithTypeEncoding:type];
                [value writePointer:ret typeEncode:type];
            }
        }else{
            *(void **)ret = (__bridge void *)propValue;
        }
    }else{
        value = propValue;
        [value writePointer:ret typeEncode:type];
    }
}
void setterInter(ffi_cif *cif, void *ret, void **args, void *userdata){
    ORPropertyDeclare *propDef = (__bridge ORPropertyDeclare *)userdata;
    id _self = (__bridge id)(*(void **)args[0]);
    const char *type = propDef.var.typeEncode;
    id value;
    if (*type == '@') {
        value = (__bridge id)(*(void **)args[2]);
    }else{
        value = [[MFValue alloc] initTypeEncode:type pointer:args[2]];
    }
    NSString *propName = propDef.var.var.varname;
    MFPropertyModifier modifier = propDef.modifier;
    if ((modifier & MFPropertyModifierMemMask) == MFPropertyModifierMemWeak) {
        value = [[MFWeakPropertyBox alloc] initWithTarget:value];
    }
    objc_AssociationPolicy associationPolicy = mf_AssociationPolicy_with_PropertyModifier(modifier);
    objc_setAssociatedObject(_self, mf_propKey(propName), value, associationPolicy);
}

static void replace_getter_method(Class clazz, ORPropertyDeclare *prop){
    SEL getterSEL = NSSelectorFromString(prop.var.var.varname);
    const char *retTypeEncoding  = prop.var.typeEncode;
    ffi_type *returnType = mf_ffi_type_with_type_encoding(retTypeEncoding);
    unsigned int argCount = 2;
    ffi_type **argTypes = malloc(sizeof(ffi_type *) * argCount);
    argTypes[0] = &ffi_type_pointer;
    argTypes[1] = &ffi_type_pointer;
    void *imp = NULL;
    ffi_cif *cifPtr = malloc(sizeof(ffi_cif));
    ffi_prep_cif(cifPtr, FFI_DEFAULT_ABI, argCount, returnType, argTypes);
    ffi_closure *closure = ffi_closure_alloc(sizeof(ffi_closure), (void **)&imp);
    ffi_prep_closure_loc(closure, cifPtr, getterInter, (__bridge void *)prop, imp);
    const char * typeEncoding = mf_str_append(retTypeEncoding, "@:");
    class_replaceMethod(clazz, getterSEL, (IMP)imp, typeEncoding);
    free((void *)typeEncoding);
}

static void replace_setter_method(Class clazz, ORPropertyDeclare *prop){
    NSString *name = prop.var.var.varname;
    NSString *str1 = [[name substringWithRange:NSMakeRange(0, 1)] uppercaseString];
    NSString *str2 = name.length > 1 ? [name substringFromIndex:1] : nil;
    SEL setterSEL = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",str1,str2]);
    const char *prtTypeEncoding  = prop.var.typeEncode;
    ffi_type *returnType = &ffi_type_void;
    unsigned int argCount = 3;
    ffi_type **argTypes = malloc(sizeof(ffi_type *) * argCount);
    argTypes[0] = &ffi_type_pointer;
    argTypes[1] = &ffi_type_pointer;
    argTypes[2] = mf_ffi_type_with_type_encoding(prtTypeEncoding);
    if (argTypes[2] == NULL) {
//        mf_throw_error(lineNumber, @"", @"");
    }
    void *imp = NULL;
    ffi_cif *cifPtr = malloc(sizeof(ffi_cif));
    ffi_prep_cif(cifPtr, FFI_DEFAULT_ABI, argCount, returnType, argTypes);
    ffi_closure *closure = ffi_closure_alloc(sizeof(ffi_closure), (void **)&imp);
    ffi_prep_closure_loc(closure, cifPtr, setterInter, (__bridge void *)prop, imp);
    const char * typeEncoding = mf_str_append("v@:", prtTypeEncoding);
    class_replaceMethod(clazz, setterSEL, (IMP)imp, typeEncoding);
    free((void *)typeEncoding);
}

void copy_undef_var(id exprOrStatement, MFVarDeclareChain *chain, MFScopeChain *fromScope, MFScopeChain *destScope);
void copy_undef_vars(NSArray *exprOrStatements, MFVarDeclareChain *chain, MFScopeChain *fromScope, MFScopeChain *destScope){
    for (id exprOrStatement in exprOrStatements) {
        copy_undef_var(exprOrStatement, chain, fromScope, destScope);
    }
}
/// Block执行时的外部变量捕获
void copy_undef_var(id exprOrStatement, MFVarDeclareChain *chain, MFScopeChain *fromScope, MFScopeChain *destScope){
    if (!exprOrStatement) {
        return;
    }
    Class exprOrStatementClass = [exprOrStatement class];
    if (exprOrStatementClass == [ORValueExpression class]) {
        ORValueExpression *expr = (ORValueExpression *)exprOrStatement;
        switch (expr.value_type) {
            case OCValueDictionary:{
                for (NSArray *kv in expr.value) {
                    ORExpression *keyExp = kv.firstObject;
                    ORExpression *valueExp = kv.firstObject;
                    copy_undef_var(keyExp, chain, fromScope, destScope);
                    copy_undef_var(valueExp, chain, fromScope, destScope);
                }
                break;
            }
            case OCValueArray:{
                for (ORExpression *valueExp in expr.value) {
                    copy_undef_var(valueExp, chain, fromScope, destScope);
                }
                break;
            }
            case OCValueSelf:
            case OCValueSuper:{
                NSString *identifier = @"self";
                if (![chain isInChain:identifier]) {
                    MFValue *value = [fromScope getValueWithIdentifier:identifier endScope:[MFScopeChain topScope]];
                    if (value) {
                        [destScope setValue:value withIndentifier:identifier];
                    }
                }
                break;
            }
            case OCValueVariable:{
                NSString *identifier = expr.value;
                if (![chain isInChain:identifier]) {
                   MFValue *value = [fromScope getValueWithIdentifier:identifier endScope:[MFScopeChain topScope]];
                    if (value) {
                        [destScope setValue:value withIndentifier:identifier];
                    }
                }
            }
            default:
                break;
        }
    }else if (exprOrStatementClass == ORAssignExpression.class) {
        ORAssignExpression *expr = (ORAssignExpression *)exprOrStatement;
        copy_undef_var(expr.value, chain, fromScope, destScope);
        copy_undef_var(expr.expression, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORBinaryExpression.class){
        ORBinaryExpression *expr = (ORBinaryExpression *)exprOrStatement;
        copy_undef_var(expr.left, chain, fromScope, destScope);
        copy_undef_var(expr.right, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORTernaryExpression.class){
        ORTernaryExpression *expr = (ORTernaryExpression *)exprOrStatement;
        copy_undef_var(expr.expression, chain, fromScope, destScope);
        copy_undef_vars(expr.values, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORUnaryExpression.class){
        ORUnaryExpression *expr = (ORUnaryExpression *)exprOrStatement;
        copy_undef_var(expr.value, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORCFuncCall.class){
        ORCFuncCall *expr = (ORCFuncCall *)exprOrStatement;
        copy_undef_var(expr.caller, chain, fromScope, destScope);
        copy_undef_vars(expr.expressions, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORSubscriptExpression.class){
        ORSubscriptExpression *expr = (ORSubscriptExpression *)exprOrStatement;
        copy_undef_var(expr.caller, chain, fromScope, destScope);
        copy_undef_var(expr.keyExp, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORMethodCall.class){
        ORMethodCall *expr = (ORMethodCall *)exprOrStatement;
        copy_undef_var(expr.caller, chain, fromScope, destScope);
        copy_undef_vars(expr.values, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORBlockImp.class){
        ORBlockImp *expr = (ORBlockImp *)exprOrStatement;
        ORFuncDeclare *funcDeclare = expr.declare;
        MFVarDeclareChain *funcChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        NSArray <ORTypeVarPair *>*params = funcDeclare.funVar.pairs;
        for (ORTypeVarPair *param in params) {
            [funcChain addIndentifer:param.var.varname];
        }
        copy_undef_vars(expr.statements, funcChain, fromScope, destScope);
        return;
    }
//    else if (exprOrStatementClass == MFExpressionStatement.class){
//        MFExpressionStatement *statement = (MFExpressionStatement *)exprOrStatement;
//        copy_undef_var(statement.expr, chain, fromScope, endScope, destScope);
//        return;
//    }
    else if (exprOrStatementClass == ORDeclareExpression.class){
        ORDeclareExpression *expr = (ORDeclareExpression *)exprOrStatement;
        NSString *name = expr.pair.var.varname;
        [chain addIndentifer:name];
        copy_undef_var(expr.expression, chain, fromScope, destScope);
        return;
        
    }else if (exprOrStatementClass == ORIfStatement.class){
        ORIfStatement *ifStatement = (ORIfStatement *)exprOrStatement;
        copy_undef_var(ifStatement.condition, chain, fromScope, destScope);
        MFVarDeclareChain *ifChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(ifStatement.funcImp, ifChain, fromScope, destScope);
        copy_undef_var(ifStatement.last, chain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORSwitchStatement.class){
        ORSwitchStatement *swithcStatement = (ORSwitchStatement *)exprOrStatement;
        copy_undef_var(swithcStatement.value, chain, fromScope, destScope);
        copy_undef_vars(swithcStatement.cases, chain, fromScope, destScope);
        MFVarDeclareChain *defChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(swithcStatement.funcImp, defChain, fromScope, destScope);
        return;
        
    }else if (exprOrStatementClass == ORCaseStatement.class){
        ORCaseStatement *caseStatement = (ORCaseStatement *)exprOrStatement;
        copy_undef_var(caseStatement.value, chain, fromScope, destScope);
        MFVarDeclareChain *caseChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(caseStatement.funcImp, caseChain, fromScope, destScope);
        return;
    }else if (exprOrStatementClass == ORForStatement.class){
        ORForStatement *forStatement = (ORForStatement *)exprOrStatement;
        MFVarDeclareChain *forChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_vars(forStatement.varExpressions, forChain, fromScope, destScope);
        copy_undef_var(forStatement.condition, forChain, fromScope, destScope);
        copy_undef_vars(forStatement.expressions, forChain, fromScope, destScope);
        copy_undef_var(forStatement.funcImp, forChain, fromScope, destScope);
    }else if (exprOrStatementClass == ORForInStatement.class){
        ORForInStatement *forEachStatement = (ORForInStatement *)exprOrStatement;
        MFVarDeclareChain *forEachChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(forEachStatement.expression, forEachChain, fromScope, destScope);
        copy_undef_var(forEachStatement.value, forEachChain, fromScope, destScope);
        copy_undef_var(forEachStatement.funcImp, forEachChain, fromScope, destScope);
    }else if (exprOrStatementClass == ORWhileStatement.class){
        ORWhileStatement *whileStatement = (ORWhileStatement *)exprOrStatement;
        copy_undef_var(whileStatement.condition, chain, fromScope, destScope);
        MFVarDeclareChain *whileChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(whileStatement.funcImp, whileChain, fromScope, destScope);
    }else if (exprOrStatementClass == ORDoWhileStatement.class){
        ORDoWhileStatement *doWhileStatement = (ORDoWhileStatement *)exprOrStatement;
        copy_undef_var(doWhileStatement.condition, chain, fromScope, destScope);
        MFVarDeclareChain *doWhileChain = [MFVarDeclareChain varDeclareChainWithNext:chain];
        copy_undef_var(doWhileStatement.funcImp, doWhileChain, fromScope, destScope);
    }else if (exprOrStatementClass == ORReturnStatement.class){
        ORReturnStatement *returnStatement = (ORReturnStatement *)exprOrStatement;
        copy_undef_var(returnStatement.expression, chain, fromScope, destScope);
    }else if (exprOrStatementClass == ORContinueStatement.class){
        
    }else if (exprOrStatementClass == ORBreakStatement.class){
        
    }
}
@implementation ORCodeCheck(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    return nil;
}

@end
@implementation ORFuncVariable (Execute)
- (id)copy{
    ORFuncVariable *var = [ORFuncVariable copyFromVar:self];
    var.pairs = self.pairs;
    return var;
}
@end
@implementation ORFuncDeclare(Execute)
- (instancetype)copy{
    ORFuncDeclare *declare = [ORFuncDeclare new];
    declare.funVar = [self.funVar copy];
    declare.returnType = self.returnType;
    return declare;
}
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSMutableArray * parameters = [[MFStack argsStack] pop];
    [parameters enumerateObjectsUsingBlock:^(MFValue * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [scope setValue:obj withIndentifier:self.funVar.pairs[idx].var.varname];
    }];
    return nil;
}
@end
@implementation ORValueExpression (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    switch (self.value_type) {
        case OCValueVariable:{
            MFValue *value = [scope getValueWithIdentifierInChain:self.value];
            if (!value) {
                value = [MFValue valueWithClass:NSClassFromString(self.value)];
            }
            NSCAssert(value, @"must exsited");
            return value;
        }
        case OCValueSelf:
        case OCValueSuper:{
            return [scope getValueWithIdentifier:@"self"];
        }
        case OCValueSelector:{
            return [MFValue valueWithSEL:NSSelectorFromString(self.value)];
        }
//        case OCValueProtocol:{
//            return [MFValue valueInstanceWithObject:NSProtocolFromString(self.value)];
//        }
        case OCValueDictionary:{
            NSMutableArray *exps = self.value;
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            for (NSMutableArray <ORExpression *>*kv in exps) {
                ORExpression *keyExp = kv.firstObject;
                ORExpression *valueExp = kv.firstObject;
                id key = [keyExp execute:scope].objectValue;
                id value = [valueExp execute:scope].objectValue;
                NSAssert(key == nil, @"the key of NSDictionary can't be nil");
                NSAssert(value == nil, @"the vale of NSDictionary can't be nil");
                dict[key] = value;
            }
            return [MFValue valueWithObject:[dict copy]];
        }
        case OCValueArray:{
            NSMutableArray *exps = self.value;
            NSMutableArray *array = [NSMutableArray array];
            for (ORExpression *exp in exps) {
                id value = [exp execute:scope].objectValue;
                NSAssert(value != nil, @"the vale of NSArray can't be nil");
                [array addObject:value];
            }
            return [MFValue valueWithObject:[array copy]];
        }
        case OCValueNSNumber:{
            MFValue *value = [self.value execute:scope];
            NSNumber *result = nil;
            UnaryExecuteBaseType(result, @, value);
            return [MFValue valueWithObject:result];
        }
        case OCValueString:{
            return [MFValue valueWithObject:self.value];
        }
        case OCValueCString:{
            NSString *value = self.value;
            char * cstring = malloc(value.length * sizeof(char));
            memcpy(cstring, value.UTF8String, value.length * sizeof(char));
            return [MFValue valueWithCString:cstring];
        }
        case OCValueInt:{
            NSString *value = self.value;
            return [MFValue valueWithLongLong:value.longLongValue];
        }
        case OCValueDouble:{
            NSString *value = self.value;
            return [MFValue valueWithDouble:value.doubleValue];
        }
        case OCValueNil:{
            return [MFValue valueWithObject:nil];
        }
        case OCValueNULL:{
            return [MFValue valueWithPointer:NULL];
        }
        case OCValueBOOL:{
            return [MFValue valueWithBOOL:[self.value isEqual:@"YES"] ? YES: NO];
            break;
        }
        default:
            break;
    }
    return [MFValue valueWithObject:nil];
}
@end
@implementation ORMethodCall(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *variable = [self.caller execute:scope];
    if (variable.type == TypeStruct) {
        return [variable fieldForKey:self.names.firstObject];;
    }
    id instance = variable.objectValue;
    if (!instance) {
        if (variable.type == TypeClass) {
            instance = *(Class *)variable.pointer;
        }else{
            NSCAssert(0, @"objectValue or classValue must has one");
        }
    }
    SEL sel = NSSelectorFromString(self.selectorName);
    NSMutableArray <MFValue *>*argValues = [NSMutableArray array];
    for (ORValueExpression *exp in self.values){
        [argValues addObject:[exp execute:scope]];
    }
    if (self.caller.value_type == OCValueSuper) {
        return invoke_sueper_values(instance, sel, argValues);
    }
    NSMethodSignature *sig = [instance methodSignatureForSelector:sel];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    invocation.target = instance;
    invocation.selector = sel;
    NSUInteger argCount = [sig numberOfArguments];
    //根据MFValue的type传入值的原因: 模拟在OC中的调用
    //FIXME: 多参数问题，self.values.count + 2 > argCount 时，采用多参数，超出参数压栈
    for (NSUInteger i = 2; i < argCount; i++) {
        MFValue *value = argValues[i-2];
        // 基础类型转换
        value.typeEncode = [sig getArgumentTypeAtIndex:i];
        [invocation setArgument:value.pointer atIndex:i];
    }
    // func replaceIMP execute
    [invocation invoke];
    char *returnType = (char *)[sig methodReturnType];
    returnType = removeTypeEncodingPrefix(returnType);
    if (*returnType == 'v') {
        return [MFValue voidValue];
    }
    void *retValuePointer = alloca([sig methodReturnLength]);
    [invocation getReturnValue:retValuePointer];
    NSString *selectorName = NSStringFromSelector(sel);
    if ([selectorName isEqualToString:@"alloc"] || [selectorName isEqualToString:@"new"] ||
        [selectorName isEqualToString:@"copy"] || [selectorName isEqualToString:@"mutableCopy"]) {
        return [[MFValue alloc] initTypeEncode:returnType pointer:retValuePointer];
    }else{
        return [[MFValue alloc] initTypeEncode:returnType pointer:retValuePointer];
    }
    
}
@end
@implementation ORCFuncCall(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSMutableArray *args = [NSMutableArray array];
    for (ORValueExpression *exp in self.expressions){
        MFValue *value = [exp execute:scope];
        NSCAssert(value != nil, @"value must be existed");
        [args addObject:value];
    }
    if ([self.caller isKindOfClass:[ORMethodCall class]] && [(ORMethodCall *)self.caller isDot]){
        // TODO: 调用block
        // make.left.equalTo(xxxx);
        MFValue *value = [(ORMethodCall *)self.caller execute:scope];
        //FIXME: see initWithCValuePointer 'FIXME' note
        return invoke_MFBlockValue(value, args);
//        if (value.typePair.type.type == TypeBlock) {
//            return invoke_MFBlockValue(value, args);
//        }else{
//            NSCAssert(0, @"must be a block value");
//        }
    }
    MFValue *blockValue = [scope getValueWithIdentifier:self.caller.value];
    if (self.caller.value_type == OCValueVariable && blockValue != nil) {
        if (blockValue.type == TypeBlock) {
            return invoke_MFBlockValue(blockValue, args);
        }else{
            // global function calll
            [[MFStack argsStack] push:args];
            ORBlockImp *imp = blockValue.objectValue;
            return [imp execute:scope];
        }
    }
    return [MFValue valueWithObject:nil];
}
@end
@implementation ORBlockImp(Execute)
- (instancetype)transform2FunImp{
    ORBlockImp *imp = [ORBlockImp new];
    imp.declare = [self.declare copy];
    imp.value = self.value;
    imp.value_type = self.value_type;
    imp.statements = self.statements;
    imp.declare.funVar.ptCount = 0;
    return imp;
}
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    // C函数声明执行, 向全局作用域注册函数
    if (scope == [MFScopeChain topScope] && self.declare && self.declare.funVar.ptCount == 0) {
        NSString *funcName = self.declare.funVar.varname;
        if ([scope getValueWithIdentifier:funcName] == nil) {
            [scope setValue:[MFValue valueWithObject:self] withIndentifier:funcName];
            return [MFValue voidValue];
        }
    }
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    if (self.declare) {
        if(self.declare.isBlockDeclare){
            // xxx = ^void (int x){ }, block作为值
            MFBlock *manBlock = [[MFBlock alloc] init];
            manBlock.func = [self transform2FunImp];
            MFScopeChain *blockScope = [MFScopeChain scopeChainWithNext:[MFScopeChain topScope]];
            copy_undef_var(self, [MFVarDeclareChain new], scope, blockScope);
            manBlock.outScope = blockScope;
            const char *typeEncoding = manBlock.func.declare.returnType.typeEncode;
            typeEncoding = mf_str_append(typeEncoding, "@?");
            for (ORTypeVarPair *param in manBlock.func.declare.funVar.pairs) {
                const char *paramTypeEncoding = param.typeEncode;
                typeEncoding = mf_str_append(typeEncoding, paramTypeEncoding);
            }
            manBlock.typeEncoding = typeEncoding;
            __autoreleasing id ocBlock = [manBlock ocBlock];
            MFValue *value = [MFValue valueWithBlock:ocBlock];
            CFRelease((__bridge void *)ocBlock);
            return value;
        }else{
            [self.declare execute:current];
        }
    }
    //{ }
    for (id <OCExecute>statement in self.statements) {
        MFValue *result = [statement execute:current];
        if (!result.isNormal) {
            return result;
        }
    }
    return [MFValue normalEnd];
}
@end
@implementation ORSubscriptExpression(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *bottomValue = [self.keyExp execute:scope];
    MFValue *arrValue = [self.caller execute:scope];
    return [arrValue subscriptGetWithIndex:bottomValue];
}
@end
@implementation ORAssignExpression (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    ORExpression *resultExp;
#define SetResultExpWithBinaryOperator(type)\
    ORBinaryExpression *exp = [ORBinaryExpression new];\
    exp.left = self.value;\
    exp.right = self.expression;\
    exp.operatorType = type;\
    resultExp = exp;
    switch (self.assignType) {
        case AssignOperatorAssign:
            resultExp = self.expression;
            break;
        case AssignOperatorAssignAnd:{
            SetResultExpWithBinaryOperator(BinaryOperatorAnd);
            break;
        }
        case AssignOperatorAssignOr:{
            SetResultExpWithBinaryOperator(BinaryOperatorOr);
            break;
        }
        case AssignOperatorAssignXor:{
            SetResultExpWithBinaryOperator(BinaryOperatorXor);
            break;
        }
        case AssignOperatorAssignAdd:{
            SetResultExpWithBinaryOperator(BinaryOperatorAdd);
            break;
        }
        case AssignOperatorAssignSub:{
            SetResultExpWithBinaryOperator(BinaryOperatorSub);
            break;
        }
        case AssignOperatorAssignDiv:{
            SetResultExpWithBinaryOperator(BinaryOperatorDiv);
            break;
        }
        case AssignOperatorAssignMuti:{
            SetResultExpWithBinaryOperator(BinaryOperatorMulti);
            break;
        }
        case AssignOperatorAssignMod:{
            SetResultExpWithBinaryOperator(BinaryOperatorMod);
            break;
        }
        case AssignOperatorAssignShiftLeft:{
            SetResultExpWithBinaryOperator(BinaryOperatorShiftLeft);
            break;
        }
        case AssignOperatorAssignShiftRight:{
            SetResultExpWithBinaryOperator(BinaryOperatorShiftRight);
            break;
        }
        default:
            break;
    }
    
    switch (self.value.value_type) {
        case OCValueSelf:{
            MFValue *resultValue = [resultExp execute:scope];
            [scope assignWithIdentifer:@"self" value:resultValue];
            break;
        }
        case OCValueVariable:{
            MFValue *resultValue = [resultExp execute:scope];
            [scope assignWithIdentifer:(NSString *)self.value.value value:resultValue];
            break;
        }
        case OCValueMethodCall:{
            ORMethodCall *methodCall = (ORMethodCall *)self.value;
            if (!methodCall.isDot) {
                NSCAssert(0, @"must dot grammar");
            }
            //调用对象setter方法
            NSString *setterName = methodCall.names.firstObject;
            NSString *first = [[setterName substringToIndex:1] uppercaseString];
            NSString *other = setterName.length > 1 ? [setterName substringFromIndex:1] : nil;
            setterName = [NSString stringWithFormat:@"set%@%@",first,other];
            ORMethodCall *setCaller = [ORMethodCall new];
            setCaller.caller = [(ORMethodCall *)self.value caller];
            setCaller.names = [@[setterName] mutableCopy];
            setCaller.values = [@[resultExp] mutableCopy];
            [setCaller execute:scope];
            break;
        }
        case OCValueCollectionGetValue:{
            MFValue *resultValue = [resultExp execute:scope];
            ORSubscriptExpression *subExp = (ORSubscriptExpression *)self.value;
            MFValue *caller = [subExp.caller execute:scope];
            MFValue *indexValue = [subExp.keyExp execute:scope];
            [caller subscriptSetValue:resultValue index:indexValue];
        }
        default:
            break;
    }
    return [MFValue normalEnd];
}
@end
@implementation ORDeclareExpression (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    BOOL staticVar = self.modifier & ORDeclarationModifierStatic;
    MFValue *(^initializeBlock)(void) = ^MFValue *{
        if (self.expression) {
            MFValue *value = [self.expression execute:scope];
            value.modifier = self.modifier;
            if (value.type != TypeBlock) {
                [value setTypeInfoWithTypePair:self.pair];
            }
            ORStructDeclare *structDecl = [[ORStructDeclareTable shareInstance] getStructDeclareWithName:self.pair.type.name];
            if (structDecl) {
                value.typeEncode = structDecl.typeEncoding;
            }
            if (value.type == TypeObject && [value.objectValue isMemberOfClass:[NSObject class]]) {
                NSString *reason = [NSString stringWithFormat:@"Unknown Class: %@",value.typeName];
                @throw [NSException exceptionWithName:@"OCRunner" reason:reason userInfo:nil];
            }
            [scope setValue:value withIndentifier:self.pair.var.varname];
            return value;
        }else{
            MFValue *value = [MFValue defaultValueWithTypeEncoding:self.pair.typeEncode];
            value.modifier = self.modifier;
            [value setTypeInfoWithTypePair:self.pair];
            if (value.type == TypeObject
                && NSClassFromString(value.typeName) == nil
                && ![value.typeName isEqualToString:@"id"]) {
                NSString *reason = [NSString stringWithFormat:@"Unknown Type Identifier: %@",value.typeName];
                @throw [NSException exceptionWithName:@"OCRunner" reason:reason userInfo:nil];
            }
            [scope setValue:value withIndentifier:self.pair.var.varname];
            return value;
        }
    };
    if (staticVar) {
        NSString *key = [NSString stringWithFormat:@"%p",(void *)self];
        MFValue *value = [[MFStaticVarTable shareInstance] getStaticVarValueWithKey:key];
        if (value) {
            [scope setValue:value withIndentifier:self.pair.var.varname];
        }else{
            MFValue *value = initializeBlock();
            [[MFStaticVarTable shareInstance] setStaticVarValue:value withKey:key];
        }
    }else{
        initializeBlock();
    }
    return [MFValue normalEnd];
}@end
@implementation ORUnaryExpression (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *currentValue = [self.value execute:scope];
    MFValue *resultValue = [[MFValue alloc] initTypeEncode:currentValue.typeEncode];
    switch (self.operatorType) {
        case UnaryOperatorIncrementSuffix:{
            startBox(resultValue);
            SuffixUnaryExecuteInt(++, currentValue);
            SuffixUnaryExecuteFloat(++, currentValue);
            endBox(resultValue);
            break;
        }
        case UnaryOperatorDecrementSuffix:{
            startBox(resultValue);
            SuffixUnaryExecuteInt(--, currentValue);
            SuffixUnaryExecuteFloat(--, currentValue);
            endBox(resultValue);
            break;
        }
        case UnaryOperatorIncrementPrefix:{
            startBox(resultValue);
            PrefixUnaryExecuteInt(++, currentValue);
            endBox(resultValue);
            break;
        }
        case UnaryOperatorDecrementPrefix:{
            startBox(resultValue);
            PrefixUnaryExecuteInt(--, currentValue);
            PrefixUnaryExecuteFloat(--, currentValue);
            endBox(resultValue);
            break;
        }
        case UnaryOperatorNot:{
            return [MFValue valueWithBOOL:!currentValue.isSubtantial];
        }
        case UnaryOperatorSizeOf:{
            size_t result = 0;
            UnaryExecute(result, sizeof, currentValue);
            return [MFValue valueWithLongLong:result];
        }
        case UnaryOperatorBiteNot:{
            startBox(resultValue);
            PrefixUnaryExecuteInt(~, currentValue);
            endBox(resultValue);
            break;
        }
        case UnaryOperatorNegative:{
            startBox(resultValue);
            PrefixUnaryExecuteInt(-, currentValue);
            PrefixUnaryExecuteFloat(-, currentValue);;
            endBox(resultValue);
            break;
        }
        case UnaryOperatorAdressPoint:{
            void *pointer = currentValue.pointer;
            resultValue.pointer = &pointer;
            resultValue.pointerCount += 1;
            return resultValue;
        }
        case UnaryOperatorAdressValue:{
            resultValue.pointer = *(void **)currentValue.pointer;
            resultValue.pointerCount -= 1;
            return resultValue;
        }
        default:
            break;
    }
    return resultValue;
}@end
@implementation ORBinaryExpression(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *rightValue = [self.right execute:scope];
    MFValue *leftValue = [self.left execute:scope];
    MFValue *resultValue = [[MFValue alloc] initTypeEncode:leftValue.typeEncode];
    switch (self.operatorType) {
        case BinaryOperatorAdd:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, +, rightValue, resultValue);
            BinaryExecuteFloat(leftValue, +, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorSub:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, -, rightValue, resultValue);
            BinaryExecuteFloat(leftValue, -, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorDiv:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, /, rightValue, resultValue);
            BinaryExecuteFloat(leftValue, /, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorMulti:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, *, rightValue, resultValue);
            BinaryExecuteFloat(leftValue, *, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorMod:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, %, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorShiftLeft:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, <<, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorShiftRight:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, >>, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorAnd:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, &, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorOr:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, |, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorXor:{
            startBox(leftValue);
            BinaryExecuteInt(leftValue, ^, rightValue, resultValue);
            endBox(resultValue);
            break;
        }
        case BinaryOperatorLT:{
            LogicBinaryOperatorExecute(leftValue, <, rightValue);
            return [MFValue valueWithBOOL:logicResultValue];
        }
        case BinaryOperatorGT:{
            LogicBinaryOperatorExecute(leftValue, >, rightValue);
            return [MFValue valueWithBOOL:logicResultValue];
        }
        case BinaryOperatorLE:{
            LogicBinaryOperatorExecute(leftValue, <=, rightValue);
            return [MFValue valueWithBOOL:logicResultValue];
        }
        case BinaryOperatorGE:{
            LogicBinaryOperatorExecute(leftValue, >=, rightValue);
            return [MFValue valueWithBOOL:logicResultValue];
        }
        case BinaryOperatorNotEqual:{
            LogicBinaryOperatorExecute(leftValue, !=, rightValue);
            return [MFValue valueWithBOOL:logicResultValue];
        }
        case BinaryOperatorEqual:{
            LogicBinaryOperatorExecute(leftValue, ==, rightValue);
            return [MFValue valueWithBOOL:logicResultValue];
        }
        case BinaryOperatorLOGIC_AND:{
            LogicBinaryOperatorExecute(leftValue, &&, rightValue);
            return [MFValue valueWithBOOL:logicResultValue];
        }
        case BinaryOperatorLOGIC_OR:{
            LogicBinaryOperatorExecute(leftValue, ||, rightValue);
            return [MFValue valueWithBOOL:logicResultValue];
        }
        default:
            break;
    }
    return resultValue;
}
@end
@implementation ORTernaryExpression(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *condition = [self.expression execute:scope];
    if (self.values.count == 1) { // condition ?: value
        if (condition.isSubtantial) {
            return condition;
        }else{
            return [self.values.lastObject execute:scope];
        }
    }else{ // condition ? value1 : value2
        if (condition.isSubtantial) {
            return [self.values.firstObject execute:scope];
        }else{
            return [self.values.lastObject execute:scope];
        }
    }
}
@end
@implementation ORStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    return [MFValue normalEnd];;
}@end
@implementation ORIfStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSMutableArray *statements = [NSMutableArray array];
    ORIfStatement *ifStatement = self;
    while (ifStatement) {
        [statements insertObject:ifStatement atIndex:0];
        ifStatement = ifStatement.last;
    }
    for (ORIfStatement *statement in statements) {
        MFValue *conditionValue = [statement.condition execute:scope];
        if (conditionValue.isSubtantial) {
            return [statement.funcImp execute:scope];
        }
    }
    if (self.condition == nil) {
        return [self.funcImp execute:scope];
    }
    return [MFValue normalEnd];
}@end
@implementation ORWhileStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    while (1) {
        if (![self.condition execute:scope].isSubtantial) {
            break;
        }
        MFValue *resultValue = [self.funcImp execute:scope];
        if (resultValue.isBreak) {
            resultValue.resultType = MFStatementResultTypeNormal;
            break;
        }else if (resultValue.isContinue){
            resultValue.resultType = MFStatementResultTypeNormal;
        }else if (resultValue.isReturn){
            return resultValue;
        }else if (resultValue.isNormal){
            
        }
    }
    return [MFValue normalEnd];
}
@end
@implementation ORDoWhileStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    while (1) {
        MFValue *resultValue = [self.funcImp execute:scope];
        if (resultValue.isBreak) {
            resultValue.resultType = MFStatementResultTypeNormal;
            break;
        }else if (resultValue.isContinue){
            resultValue.resultType = MFStatementResultTypeNormal;
        }else if (resultValue.isReturn){
            return resultValue;
        }else if (resultValue.isNormal){
            
        }
        if (![self.condition execute:scope].isSubtantial) {
            break;
        }
    }
    return [MFValue normalEnd];
}
@end
@implementation ORCaseStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    return [self.funcImp execute:scope];
}@end
@implementation ORSwitchStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *value = [self.value execute:scope];
    BOOL hasMatch = NO;
    for (ORCaseStatement *statement in self.cases) {
        if (statement.value) {
            if (!hasMatch) {
                MFValue *caseValue = [statement.value execute:scope];
                LogicBinaryOperatorExecute(value, ==, caseValue);
                hasMatch = logicResultValue;
                if (!hasMatch) {
                    continue;
                }
            }
            MFValue *result = [statement.funcImp execute:scope];
            if (result.isBreak) {
                result.resultType = MFStatementResultTypeNormal;
                return result;
            }else if (result.isNormal){
                continue;
            }else{
                return result;
            }
        }else{
            MFValue *result = [statement.funcImp execute:scope];
            if (result.isBreak) {
                result.resultType = MFStatementResultTypeNormal;
                return value;
            }
        }
    }
    return [MFValue normalEnd];
}@end
@implementation ORForStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    for (ORExpression *exp in self.varExpressions) {
        [exp execute:current];
    }
    while (1) {
        if (![self.condition execute:current].isSubtantial) {
            break;
        }
        MFValue *result = [self.funcImp execute:current];
        if (result.isReturn) {
            return result;
        }else if (result.isBreak){
            result.resultType = MFStatementResultTypeNormal;
            return result;
        }else if (result.isContinue){
            continue;
        }
        for (ORExpression *exp in self.expressions) {
            [exp execute:(MFScopeChain *)current];
        }
    }
    return [MFValue normalEnd];
}@end
@implementation ORForInStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    MFValue *arrayValue = [self.value execute:current];
    for (id element in arrayValue.objectValue) {
        //TODO: 每执行一次，在作用域中重新设置一次
        [current setValue:[MFValue valueWithObject:element] withIndentifier:self.expression.pair.var.varname];
        MFValue *result = [self.funcImp execute:current];
        if (result.isBreak) {
            result.resultType = MFStatementResultTypeNormal;
            return result;
        }else if(result.isContinue){
            continue;
        }else if (result.isReturn){
            return result;
        }
    }
    return [MFValue normalEnd];
}
@end
@implementation ORReturnStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    if (self.expression) {
        MFValue *value = [self.expression execute:scope];
        value.resultType = MFStatementResultTypeReturnValue;
        return value;
    }else{
        MFValue *value = [MFValue voidValue];
        value.resultType = MFStatementResultTypeReturnEmpty;
        return value;
    }
}
@end
@implementation ORBreakStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *value = [MFValue voidValue];
    value.resultType = MFStatementResultTypeBreak;
    return value;
}
@end
@implementation ORContinueStatement (Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFValue *value = [MFValue voidValue];
    value.resultType = MFStatementResultTypeContinue;
    return value;
}
@end
@implementation ORPropertyDeclare(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSString *propertyName = self.var.var.varname;
    MFValue *classValue = [scope getValueWithIdentifier:@"Class"];
    Class class = *(Class *)classValue.pointer;
    class_replaceProperty(class, [propertyName UTF8String], self.propertyAttributes, 3);
    MFPropertyMapTableItem *propItem = [[MFPropertyMapTableItem alloc] initWithClass:class property:self];
    [[MFPropertyMapTable shareInstance] addPropertyMapTableItem:propItem];
    replace_getter_method(class, self);
    replace_setter_method(class, self);
    return nil;
}
- (const objc_property_attribute_t *)propertyAttributes{
    NSValue *value = objc_getAssociatedObject(self, "propertyAttributes");
    objc_property_attribute_t *attributes = [value pointerValue];
    if (attributes != NULL) {
        return attributes;
    }
    attributes = malloc(sizeof(objc_property_attribute_t) * 3);
    attributes[0] = self.typeAttribute;
    attributes[1] = self.memeryAttribute;
    attributes[2] = self.atomicAttribute;
    objc_setAssociatedObject(self, "propertyAttributes", [NSValue valueWithPointer:attributes], OBJC_ASSOCIATION_ASSIGN);
    return attributes;
}
-(void)dealloc{
    NSValue *value = objc_getAssociatedObject(self, "propertyAttributes");
    objc_property_attribute_t **attributes = [value pointerValue];
    if (attributes != NULL) {
        free(attributes);
    }
}
- (objc_property_attribute_t )typeAttribute{
    objc_property_attribute_t type = {"T", self.var.typeEncode };
    return type;
}
- (objc_property_attribute_t )memeryAttribute{
    objc_property_attribute_t memAttr = {"", ""};
    switch (self.modifier & MFPropertyModifierMemMask) {
        case MFPropertyModifierMemStrong:
            memAttr.name = "&";
            break;
        case MFPropertyModifierMemWeak:
            memAttr.name = "W";
            break;
        case MFPropertyModifierMemCopy:
            memAttr.name = "C";
            break;
        default:
            break;
    }
    return memAttr;
}
- (objc_property_attribute_t )atomicAttribute{
    objc_property_attribute_t atomicAttr = {"", ""};
    switch (self.modifier & MFPropertyModifierAtomicMask) {
        case MFPropertyModifierAtomic:
            break;
        case MFPropertyModifierNonatomic:
            atomicAttr.name = "N";
            break;
        default:
            break;
    }
    return atomicAttr;
}

@end
@implementation ORMethodDeclare(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    NSMutableArray * parameters = [[MFStack argsStack] pop];
    [parameters enumerateObjectsUsingBlock:^(MFValue * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [scope setValue:obj withIndentifier:self.parameterNames[idx]];
    }];
    return nil;
}
@end

@implementation ORMethodImplementation(Execute)
- (nullable MFValue *)execute:(MFScopeChain *)scope {
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    [self.declare execute:current];
    return [self.imp execute:current];
}
@end
#import <objc/runtime.h>

@implementation ORClass(Execute)
/// 执行时，根据继承顺序执行
- (nullable MFValue *)execute:(MFScopeChain *)scope{
    Class clazz = NSClassFromString(self.className);
    MFScopeChain *current = [MFScopeChain scopeChainWithNext:scope];
    if (!clazz) {
        Class superClass = NSClassFromString(self.superClassName);
        clazz = objc_allocateClassPair(superClass, self.className.UTF8String, 0);
        objc_registerClassPair(clazz);
    }
    // 添加Class变量到作用域
    [current setValue:[MFValue valueWithClass:clazz] withIndentifier:@"Class"];
    for (ORMethodImplementation *method in self.methods) {
        replace_method(clazz, method, current);
    }
    for (ORPropertyDeclare *property in self.properties) {
        [property execute:current];
    }
    return nil;
}
@end

